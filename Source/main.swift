import Cocoa
import AVFoundation
import Vision
import SwiftUI
import Charts
import ServiceManagement
import Carbon

enum AppMode { static let screenshot = CommandLine.arguments.contains("--screenshot") || Bundle.main.object(forInfoDictionaryKey: "NailGuardScreenshotMode") as? Bool == true }

struct Episode: Codable, Identifiable {
    var id = UUID()
    var start: Date
    var duration: Double
    var falseAlarm = false
    var snapshotFile: String?
    var zones: String?
}
struct History: Codable { var episodes: [Episode] = []; var monitored: [String: Double] = [:] }
func dayKey(_ date: Date) -> String { calendarDayKey(date, calendar: .current) }

struct Settings: Codable, Equatable {
    static let overlayPositions = ["Top Left", "Top", "Top Right", "Left", "Center", "Right", "Bottom Left", "Bottom", "Bottom Right"]
    static let followOverlayPosition = "Same as overlay"

    var sensitivity = 0.1
    var hold = 1.0
    var rearm = 1.0
    var sound = true
    var soundName = "Basso"
    var volume = 1.0
    var repeatAlarm = true
    var repeatSeconds = 2.0
    var hrtCheckIn = true
    var hrtFinishSound = "Ping"
    var hrtFinishVolume = 1.0
    var hrtAutoDock = true
    var hrtDockPosition = Settings.followOverlayPosition
    var overlay = true
    var overlaySeconds = 2.0
    var overlayWidth = 420.0
    var overlayPosition = "Top"
    var screenID = "all"
    var overlayPhoto = true
    var analysisFPS = 5.0
    var resolution = "640 × 480"
    var previewFPS = 5.0
    var adaptive = true
    var efficientFaceUpdates = true
    var saveSnapshots = true
    var snapshotDays = 14.0
    var snapshotLimit = 200.0
    var overlayAccent = "Red"
    var overlayStyle = "Card"
    var dim = 0.5
    var autoMonitor = false
    var resumeAfterUnlock = false
    var resolvedHRTDockPosition: String {
        hrtDockPosition == Self.followOverlayPosition ? overlayPosition : hrtDockPosition
    }

    static func load(_ data: Data?) -> Settings {
        guard let data, var old = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaults = try? JSONEncoder().encode(Settings()),
              var merged = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any] else { return Settings() }
        if let position = old["overlayPosition"] as? String { old["overlayPosition"] = ["Góra":"Top", "Środek":"Center", "Dół":"Bottom"][position] ?? position }
        for (key, value) in old { merged[key] = value }
        guard let encoded = try? JSONSerialization.data(withJSONObject: merged), var result = try? JSONDecoder().decode(Settings.self, from: encoded) else { return Settings() }
        if !OverlayAccent.allCases.map(\.rawValue).contains(result.overlayAccent) { result.overlayAccent = Settings().overlayAccent }
        if result.overlayStyle != "Banner" { result.overlayStyle = "Card" }
        if !(["None"] + soundNames).contains(result.hrtFinishSound) { result.hrtFinishSound = "Ping" }
        result.hrtFinishVolume = min(1, max(0, result.hrtFinishVolume))
        result.hold = min(2, max(0, result.hold)); result.analysisFPS = min(15, max(2, result.analysisFPS))
        result.previewFPS = min(10, max(1, result.previewFPS)); result.volume = min(1, max(0, result.volume))
        result.rearm = min(4, max(0.3, result.rearm))
        result.repeatSeconds = min(5, max(1, result.repeatSeconds))
        result.overlaySeconds = min(10, max(1, result.overlaySeconds))
        result.overlayWidth = min(640, max(280, result.overlayWidth))
        result.dim = min(0.75, max(0, result.dim))
        result.snapshotDays = min(90, max(1, result.snapshotDays))
        result.snapshotLimit = min(1000, max(50, result.snapshotLimit))
        result.sensitivity = min(0.35, max(0.08, result.sensitivity))
        if !["640 × 480", "1280 × 720", "1920 × 1080"].contains(result.resolution) { result.resolution = "640 × 480" }
        if !overlayPositions.contains(result.overlayPosition) { result.overlayPosition = "Top" }
        if !overlayPositions.contains(result.hrtDockPosition) { result.hrtDockPosition = followOverlayPosition }
        if !soundNames.contains(result.soundName) { result.soundName = Settings().soundName }
        return result
    }
}
struct DebugFrame {
    var image: NSImage
    var mouth: CGRect?
    var zone: CGRect?
    var tips: [CGPoint]
    var aspect: CGFloat
}

// Time-based hysteresis: missing observations never count as a safe hand position.
struct GestureGate {
    var candidate: Date?
    var clearSince: Date?
    var active = false
    mutating func update(near: Bool?, at now: Date, hold: Double, rearm: Double = 1.2) -> Bool {
        guard let near else { candidate = nil; clearSince = nil; return false }
        if near {
            clearSince = nil
            if candidate == nil { candidate = now }
            if !active && now.timeIntervalSince(candidate!) >= hold { active = true; return true }
        } else {
            candidate = nil
            if clearSince == nil { clearSince = now }
            if now.timeIntervalSince(clearSince!) >= rearm { active = false }
        }
        return false
    }
}

final class Model: NSObject, ObservableObject {
    let training = PracticeController()
    @Published var dataBusy = false
    @Published var dataMessage = ""
    @Published var detectionState = "Monitoring paused"
    @Published var cpu: Double = 0
    @Published var actualCamera = "Not running"
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginStatus = ""
    @Published var expandedEvent: UUID?
    @Published var expandedImage: NSImage?
    private var lastUIPublish = 0.0
    private let cpuMeter = CPUMeter()
    private let disk = DispatchQueue(label: "NailGuard.storage", qos: .utility)
    private var storageReadable = true
    private var dirty = false
    private var tickCount = 0
    @Published var hoveredBin: Date?
    @Published var controlPage = "Detection"
    @Published var statisticsRange = "Today" { didSet { resetHistory(); refreshStatistics() } }
    @Published var statisticsStart = Calendar.current.date(byAdding: .day, value: -6, to: Date())! { didSet { resetHistory(); refreshStatistics() } }
    @Published var statisticsEnd = Date() { didSet { resetHistory(); refreshStatistics() } }
    @Published var historyExpanded = false { didSet { if !historyExpanded { expandedEvent = nil; expandedImage = nil } } }
    @Published var statistics = StatisticsSummary.empty
    func resetHistory() { hoveredBin = nil; historyExpanded = false; expandedEvent = nil; expandedImage = nil }
    func refreshStatistics() {
        guard tab == 1 else { return }
        statistics = summarize(history: history, window: StatisticsWindow.make(range: statisticsRange, from: statisticsStart, through: statisticsEnd, now: Date()))
    }
    @Published var running = false
    @Published var status = "Ready - start monitoring"
    @Published var history = History()
    @Published var snapshot: NSImage?
    @Published var fps: Double = 0
    @Published var latency: Double = 0
    @Published var settings: Settings = {
        if AppMode.screenshot { return Settings() }
        if let data = UserDefaults.standard.data(forKey: "settings.v13") ?? UserDefaults.standard.data(forKey: "settings.v12") ?? UserDefaults.standard.data(forKey: "settings.v11") { return Settings.load(data) }
        var value = Settings()
        value.sensitivity = UserDefaults.standard.object(forKey: "sensitivity") as? Double ?? value.sensitivity
        value.hold = UserDefaults.standard.object(forKey: "hold") as? Double ?? value.hold
        return value
    }() { didSet {
        if !AppMode.screenshot, let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings.v13") }
        if oldValue.soundName != settings.soundName { playSound() }
        if oldValue.hrtFinishSound != settings.hrtFinishSound && settings.hrtFinishSound != "None" {
            playSound(name: settings.hrtFinishSound, volume: settings.hrtFinishVolume)
        }
        configureDetector()
        if !settings.repeatAlarm || !settings.overlay { overlays.endRepeatingAlert() }
        if oldValue.repeatAlarm != settings.repeatAlarm || oldValue.hrtDockPosition != settings.hrtDockPosition || oldValue.overlayAccent != settings.overlayAccent || oldValue.overlayWidth != settings.overlayWidth || oldValue.overlayPosition != settings.overlayPosition || oldValue.overlayStyle != settings.overlayStyle || oldValue.overlayPhoto != settings.overlayPhoto || oldValue.dim != settings.dim || oldValue.screenID != settings.screenID { training.refreshOverlay() }
    } }
    @Published var previewEnabled = true { didSet { configureDetector(); if !previewEnabled { debugFrame = nil } } }
    @Published var tab = 0 { didSet { configureDetector(); if tab != 0 { debugFrame = nil }; resetHistory(); refreshStatistics() } }
    @Published var windowVisible = true { didSet { configureDetector(); if !windowVisible { debugFrame = nil } } }
    @Published var debugFrame: DebugFrame?
    @Published var screens: [(String, String)] = []
    private var practiceSnapshot: NSImage?
    private var practiceOfferEpisodeID: UUID?
    private var alertEscalation = AlertEscalation()
    private let boostedSound = BoostedAlertSound()
    private var playingSound: NSSound?
    let capture = Capture()
    let overlays = OverlayManager()
    private var timer: Timer?
    private var lastTick = Date()
    private var lastStart = Date()
    private var activeID: UUID?
    private var resumeState = MonitoringResumeState()
    private let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NailGuard-HRT/history.json")
    var today: [Episode] { history.episodes.filter { Calendar.current.isDateInToday($0.start) && !$0.falseAlarm } }
    var todaySeconds: Double { history.monitored[dayKey(Date())] ?? 0 }
    override init() {
        super.init()
        if !AppMode.screenshot && FileManager.default.fileExists(atPath: storage.path) {
            do { history = try JSONDecoder().decode(History.self, from: Data(contentsOf: storage)) }
            catch {
                storageReadable = false
                status = "History could not be read. Restore history.json or use More to reset statistics."
                dataMessage = status
            }
        }
        training.onInteraction = { [weak self] in self?.playingSound?.stop() }
        training.onPresent = { [weak self] in
            guard let self else { return }
            let escalation = self.settings.repeatAlarm && self.canRepeatPracticeOffer ? self.alertEscalation.level : 0
            self.overlays.showPractice(training: self.training, image: self.training.sessionSource == .camera ? self.practiceSnapshot : nil, settings: self.settings, escalation: escalation)
        }
        training.onDismiss = { [weak self] in
            self?.practiceOfferEpisodeID = nil
            self?.practiceSnapshot = nil
            self?.overlays.hide()
        }
        training.onFinish = { [weak self] in
            guard let self, self.settings.hrtFinishSound != "None" else { return }
            self.playSound(name: self.settings.hrtFinishSound, volume: self.settings.hrtFinishVolume)
        }
        refreshScreens()
        refreshLoginStatus()
        configureDetector()
        capture.result = { [weak self] result in DispatchQueue.main.async { self?.receive(result) } }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    func configureDetector() { training.autoDock = settings.hrtAutoDock; training.checkInEnabled = settings.hrtCheckIn; capture.configure(settings: settings, preview: previewEnabled && tab == 0 && windowVisible) }
    func refreshScreens() { screens = NSScreen.screens.map { (String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0), $0.localizedName) } }
    func profile(_ name: String) {
        switch name {
        case "Eco": settings.analysisFPS = 3; settings.resolution = "640 × 480"; settings.previewFPS = 2
        case "Detail": settings.analysisFPS = 10; settings.resolution = "1920 × 1080"; settings.previewFPS = 6
        default: settings.analysisFPS = 6; settings.resolution = "1280 × 720"; settings.previewFPS = 4
        }
    }
    func markFalse(_ id: UUID) { guard !dataBusy else { return }; if let i = history.episodes.firstIndex(where: { $0.id == id }) { history.episodes[i].falseAlarm.toggle(); save(); refreshStatistics() } }
    @objc func screenLocked() { suspendMonitoring(.screenLock) }
    @objc func systemWillSleep() { suspendMonitoring(.systemSleep) }
    @objc func screenUnlocked() { releaseSuspension(.screenLock) }
    @objc func systemDidWake() { releaseSuspension(.systemSleep) }
    private func suspendMonitoring(_ reason: MonitoringResumeState.Reason) {
        training.end()
        resumeState.suspend(reason, wasRunning: running)
        if running {
            stop(cancelPendingResume: false)
            status = settings.resumeAfterUnlock ? "Paused while locked or asleep - resume is enabled" : "Paused after lock or sleep - resume manually"
        }
    }
    private func releaseSuspension(_ reason: MonitoringResumeState.Reason) {
        if resumeState.release(reason, enabled: settings.resumeAfterUnlock) { start() }
    }
    func start() {
        guard !AppMode.screenshot else { return }
        guard !running && !dataBusy && !resumeState.isSuspended else { return }
        guard storageReadable else { status = "Restore the history file or reset statistics in More before starting."; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: begin()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in DispatchQueue.main.async { if granted { self?.begin() } else { self?.status = "Camera permission denied. Enable NailGuard in System Settings → Privacy & Security → Camera." } } }
        default: status = "Camera access unavailable. Enable NailGuard in System Settings → Privacy & Security → Camera."
        }
    }
    private func begin() { guard !running && !dataBusy && storageReadable && !resumeState.isSuspended else { return }; resumeState.cancel(); running = true; lastTick = Date(); lastStart = Date(); status = "Starting camera…"; capture.start() }
    func stop(cancelPendingResume: Bool = true) { if cancelPendingResume { resumeState.cancel() }; running = false; capture.stop(); finishEpisode(); if !training.busy { overlays.hide() }; snapshot = nil; debugFrame = nil; actualCamera = "Not running"; detectionState = "Monitoring paused"; fps = 0; latency = 0; status = "Monitoring paused"; save() }
    private func tick() {
        training.tick()
        let now = Date(); let elapsed = min(now.timeIntervalSince(lastTick), 2); lastTick = now
        if running && capture.isFresh { history.monitored[dayKey(now), default: 0] += elapsed; dirty = true }
        if let id = activeID, let i = history.episodes.firstIndex(where: { $0.id == id }) { history.episodes[i].duration = now.timeIntervalSince(history.episodes[i].start) }
        if running && !capture.isFresh { finishEpisode(); if now.timeIntervalSince(lastStart) > 4 { status = "Waiting for camera frames - pause and restart if this persists" } }
        tickCount += 1
        if tickCount % 2 == 0 { cpu = cpuMeter.sample() }
        if tickCount % 10 == 0 { if dirty { save() }; refreshStatistics() }
        if tickCount % 60 == 0 { pruneSnapshots() }
    }
    private var canRepeatPracticeOffer: Bool {
        guard let activeID else { return false }
        return training.cameraOfferPending && activeID == practiceOfferEpisodeID
    }

    private func finishEpisode() {
        let resetPracticeSize = canRepeatPracticeOffer && alertEscalation.level > 0
        if activeID != nil { dirty = true; refreshStatistics() }
        activeID = nil
        alertEscalation.reset()
        overlays.endRepeatingAlert(after: settings.overlaySeconds)
        if resetPracticeSize { training.refreshOverlay() }
    }
    private func receive(_ r: Detection) {
        guard running else { return }
        if let error = r.error { stop(); status = error; return }
        if previewEnabled && tab == 0 && windowVisible, let debug = r.debug { debugFrame = debug }
        let now = ProcessInfo.processInfo.systemUptime
        if tab == 0 && windowVisible && (now - lastUIPublish >= 0.5 || r.trigger) {
            status = r.message; detectionState = r.phase; fps = r.fps; latency = r.milliseconds; actualCamera = r.camera; lastUIPublish = now
        }
        if !r.active { finishEpisode() }
        else if !r.near { overlays.endRepeatingAlert(after: settings.overlaySeconds) }
        if r.trigger {
            var event = Episode(start: Date(), duration: 0)
            event.zones = r.zones
            if settings.saveSnapshots, let image = r.image {
                event.snapshotFile = event.id.uuidString + ".jpg"
                persistSnapshot(image, filename: event.snapshotFile!)
            }
            history.episodes.append(event); activeID = event.id
            snapshot = r.image
            alertEscalation.begin(at: now)
            alert(image: r.image)
            save()
            refreshStatistics()
        } else if r.near && r.active && settings.repeatAlarm {
            repeatAlert(at: now, image: r.image ?? snapshot)
        }
    }

    private func repeatAlert(at time: TimeInterval, image: NSImage?) {
        let usingHRT = training.preferences.enabled && training.available
        guard !usingHRT || canRepeatPracticeOffer else { return }
        let previousLevel = alertEscalation.level
        guard let level = alertEscalation.repeatIfDue(at: time, interval: settings.repeatSeconds) else { return }
        if usingHRT {
            if settings.sound { playSound(escalation: level) }
            if level != previousLevel { training.refreshOverlay() }
        } else {
            ordinaryAlert(image: image, escalation: level, repeating: true)
        }
    }

    func playSound(name: String? = nil, volume: Double? = nil, escalation: Int = 0) {
        let name = name ?? settings.soundName
        let volume = volume ?? settings.volume
        let louder = escalation > 0 && volume > 0 ? boostedSound.sound(named: name, volume: volume, level: escalation) : nil
        guard let audio = louder ?? (NSSound(named: NSSound.Name(name))?.copy() as? NSSound) else { return }
        playingSound?.stop()
        audio.volume = louder == nil ? Float(volume) : 1
        playingSound = audio
        audio.play()
    }

    func alert(image: NSImage?) {
        if training.preferences.enabled && training.available {
            if !training.busy { practiceSnapshot = image }
            if training.offerFromCamera() {
                practiceOfferEpisodeID = activeID
                if settings.sound { playSound() }
            }
            return
        }
        ordinaryAlert(image: image, repeating: settings.repeatAlarm)
    }

    func ordinaryAlert(image: NSImage?, escalation: Int = 0, repeating: Bool = false) {
        if settings.sound { playSound(escalation: escalation) }
        if settings.overlay { overlays.show(image: settings.overlayPhoto ? image : nil, settings: settings, escalation: escalation, repeating: repeating) }
    }
    func testAlert() {
        switch training.phase {
        case .idle: ordinaryAlert(image: debugFrame?.image)
        case .offered, .active: training.present()
        case .review: training.refreshOverlay()
        }
    }
    func save() {
        guard !AppMode.screenshot && storageReadable && !dataBusy else { return }
        let value = history
        dirty = false
        let store = LocalDataStore(root: storage.deletingLastPathComponent())
        disk.async { [weak self] in
            do { try store.write(value) }
            catch { DispatchQueue.main.async { self?.status = "Could not save history: \(error.localizedDescription)"; self?.dirty = true } }
        }
    }
    func flush() { save(); disk.sync {} }
    var snapshotsURL: URL { storage.deletingLastPathComponent().appendingPathComponent("Snapshots", isDirectory: true) }
    func persistSnapshot(_ image: NSImage, filename: String) {
        let folder = snapshotsURL
        disk.async { [weak self] in
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return }
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try jpeg.write(to: folder.appendingPathComponent(filename), options: .atomic) }
            catch { DispatchQueue.main.async { self?.status = "Snapshot could not be saved: \(error.localizedDescription)" } }
        }
        pruneSnapshots()
    }
    func pruneSnapshots() {
        guard !AppMode.screenshot else { return }
        let folder = snapshotsURL; let days = settings.snapshotDays; let limit = Int(settings.snapshotLimit)
        disk.async {
            let keys: [URLResourceKey] = [.creationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
            let dated = files.filter { $0.pathExtension == "jpg" }.map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }.sorted { $0.1 > $1.1 }
            let cutoff = Date().addingTimeInterval(-days * 86400)
            for (i, entry) in dated.enumerated() where i >= limit || entry.1 < cutoff { try? FileManager.default.removeItem(at: entry.0) }
        }
    }
    func expand(_ event: Episode) {
        if expandedEvent == event.id { expandedEvent = nil; expandedImage = nil; return }
        expandedEvent = event.id; expandedImage = nil
        guard let name = event.snapshotFile, name == event.id.uuidString + ".jpg" else { return }
        let url = snapshotsURL.appendingPathComponent(name)
        disk.async { [weak self] in
            let image = NSImage(contentsOf: url)
            DispatchQueue.main.async { if self?.expandedEvent == event.id { self?.expandedImage = image } }
        }
    }
    func confirmDataAction(_ action: DataAction) {
        guard !AppMode.screenshot && !dataBusy, let window = NSApp.mainWindow else { return }
        if action == .deleteSnapshots && !storageReadable {
            dataMessage = "History is unreadable. Restore the file or reset statistics before deleting photos."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = action.title
        alert.informativeText = action.explanation
        alert.addButton(withTitle: action.button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.performDataAction(action) }
        }
    }
    private func performDataAction(_ action: DataAction) {
        guard !dataBusy else { return }
        dataBusy = true; dataMessage = "Working..."
        stop(); resetHistory()
        let previous = history
        let store = LocalDataStore(root: storage.deletingLastPathComponent())
        disk.async { [weak self] in
            do {
                let updated = try action == .resetStatistics ? store.resetStatistics() : store.deleteSnapshots(history: previous)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.history = updated; self.storageReadable = true; self.dirty = false; self.snapshot = nil
                    self.refreshStatistics(); self.dataBusy = false
                    self.dataMessage = action == .resetStatistics ? "Statistics reset. Saved photos were kept." : "Saved photos moved to Trash. Statistics were kept."
                }
            } catch {
                DispatchQueue.main.async {
                    self?.dataBusy = false
                    self?.dataMessage = "Could not complete the action: \(error.localizedDescription)"
                }
            }
        }
    }
    func refreshLoginStatus() {
        if AppMode.screenshot { launchAtLogin = false; loginStatus = "Disabled in screenshot mode."; return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginStatus = SMAppService.mainApp.status == .requiresApproval ? "Approval required in System Settings → General → Login Items." : launchAtLogin ? "Enabled for this app location." : "Disabled. Keep the app in a permanent location before enabling."
    }
    func setLogin(_ enabled: Bool) {
        guard !AppMode.screenshot else { return }
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; refreshLoginStatus() }
        catch { refreshLoginStatus(); loginStatus = "Login item error: \(error.localizedDescription)" }
    }
}
struct Detection {
    var trigger = false; var active = false; var message: String
    var near = false
    var phase = "Uncertain detection"
    var zones = "Mouth"
    var camera = ""
    var debug: DebugFrame?
    var image: NSImage?; var fps: Double = 0; var milliseconds: Double = 0; var error: String?
}
final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "NailGuard.camera", qos: .utility)
    private let lock = NSLock()
    private var lastReceived = Date.distantPast
    var isFresh: Bool { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(lastReceived) < 2 }
    private var configured = false
    private var cameraDevice: AVCaptureDevice?
    private var lastPreview = 0.0
    private var pacer = FramePacer()
    private var lastFaceAnalysis = 0.0
    private var cachedFace: VNFaceObservation?
    private var analysisAverage = 0.0
    private var lastFaceSeen = 0.0
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private let handsRequest: VNDetectHumanHandPoseRequest = { let r = VNDetectHumanHandPoseRequest(); r.maximumHandCount = 2; return r }()
    private var previousTime = 0.0
    private var settings = Settings()
    private var preview = false
    private var gate = GestureGate()
    private var lastMouth: (CGRect, CGRect, Date)?
    private var lastFace: (CGRect, Date)?
    private var unknownSince: Date?
    private let context = CIContext(options: [.cacheIntermediates: false])
    var result: ((Detection) -> Void)?
    func configure(settings: Settings, preview: Bool) { queue.async {
        let changeResolution = self.settings.resolution != settings.resolution
        let changeRate = self.settings.analysisFPS != settings.analysisFPS

        self.settings = settings; self.preview = preview
        if changeResolution && self.configured {
            self.session.beginConfiguration()
            let preset = cameraPreset(settings.resolution)
            if self.session.canSetSessionPreset(preset) { self.session.sessionPreset = preset }
            self.session.commitConfiguration()
            self.configureDeviceFormat()
            self.gate = GestureGate(); self.lastMouth = nil; self.lastFace = nil; self.cachedFace = nil; self.lastFaceAnalysis = 0
        } else if changeRate && self.configured { self.configureDeviceFormat() }
    } }
    func configureDeviceFormat() {
        guard let camera = cameraDevice else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do { try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
            let target = captureDimensions(settings.resolution)
            let current = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            if current.width != target.width || current.height != target.height,
               let exact = camera.formats.first(where: {
                   let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                   return d.width == target.width && d.height == target.height
               }) { camera.activeFormat = exact }
            let requested = min(15, max(6, settings.analysisFPS * 2))
            let ranges = camera.activeFormat.videoSupportedFrameRateRanges
            let supported = ranges.contains { $0.minFrameRate <= requested && $0.maxFrameRate >= requested }
            let rate = supported ? requested : 15.0
            if ranges.contains(where: { $0.minFrameRate <= rate && $0.maxFrameRate >= rate }) {
                let duration = CMTime(seconds: 1 / rate, preferredTimescale: 60000)
                camera.activeVideoMinFrameDuration = duration; camera.activeVideoMaxFrameDuration = duration
            }
        } catch { }
    }
    func start() { queue.async {
        self.gate = GestureGate(); self.lastMouth = nil; self.lastFace = nil; self.cachedFace = nil; self.lastFaceAnalysis = 0; self.previousTime = 0; self.unknownSince = nil; self.pacer = FramePacer(); self.lastFaceSeen = ProcessInfo.processInfo.systemUptime
        do {
            if !self.configured {
                self.session.beginConfiguration(); defer { self.session.commitConfiguration() }
                let requested = cameraPreset(self.settings.resolution)
                if self.session.canSetSessionPreset(requested) { self.session.sessionPreset = requested }
                guard let camera = AVCaptureDevice.default(for: .video) else { throw NSError(domain: "No camera found", code: 1) }
                self.cameraDevice = camera
                let input = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(input) else { throw NSError(domain: "Cannot open camera", code: 2) }
                self.session.addInput(input)
                let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                let formats = output.availableVideoPixelFormatTypes
                let pixelFormat = formats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : formats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                output.setSampleBufferDelegate(self, queue: self.queue)
                guard self.session.canAddOutput(output) else { throw NSError(domain: "Cannot read camera", code: 3) }
                self.session.addOutput(output); self.configured = true
                self.configureDeviceFormat()
            }
        } catch {
            if !self.configured { self.session.beginConfiguration(); for input in self.session.inputs { self.session.removeInput(input) }; for output in self.session.outputs { self.session.removeOutput(output) }; self.session.commitConfiguration() }
            self.result?(Detection(message: "Camera error", error: "Camera error: \(error.localizedDescription)")); return }
        self.session.startRunning()
    } }
    func stop() { queue.async { self.session.stopRunning(); self.lock.lock(); self.lastReceived = .distantPast; self.lock.unlock(); self.gate = GestureGate(); self.lastMouth = nil; self.lastFace = nil; self.cachedFace = nil; self.lastFaceAnalysis = 0 } }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let idle = settings.adaptive && now - lastFaceSeen > 3
        let interval = max(1 / (idle ? 2 : settings.analysisFPS), settings.adaptive ? analysisAverage * 1.15 : 0)
        guard pacer.admit(now: now, interval: interval) else { return }
        lock.lock(); lastReceived = Date(); lock.unlock()
        autoreleasepool {
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let analysisImage = imageForAnalysis(CIImage(cvPixelBuffer: buffer), resolution: settings.resolution)
                let handler = VNImageRequestHandler(ciImage: analysisImage, orientation: .up)
                let date = Date()
                if !settings.efficientFaceUpdates || now - lastFaceAnalysis >= 1 / 3.0 || lastFaceAnalysis == 0 {
                    try handler.perform([faceRequest])
                    lastFaceAnalysis = now
                    let faces = faceRequest.results ?? []
                    if !faces.isEmpty { lastFaceSeen = now }
                    cachedFace = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
                    if let face = cachedFace { lastFace = (face.boundingBox, date) }
                    if let f = cachedFace, let lips = f.landmarks?.outerLips, lips.pointCount > 0 {
                        let points = lips.normalizedPoints.map { CGPoint(x: f.boundingBox.minX + CGFloat($0.x) * f.boundingBox.width, y: f.boundingBox.minY + CGFloat($0.y) * f.boundingBox.height) }
                        let xs = points.map(\.x), ys = points.map(\.y)
                        lastMouth = (CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!), f.boundingBox, date)
                    }
                }
                let face = cachedFace
                var hands: [VNHumanHandPoseObservation] = []
                if let (_, _, seen) = lastMouth, date.timeIntervalSince(seen) < 0.7 {
                    try handler.perform([handsRequest]); hands = handsRequest.results ?? []
                }
                var near: Bool? = nil
                var message = "No face visible - check your position and lighting"
                var debugMouth: CGRect?; var debugZone: CGRect?; var debugTips: [CGPoint] = []
                if let (box, seen) = lastFace, date.timeIntervalSince(seen) < 0.7 {
                    let validMouth = lastMouth.flatMap { date.timeIntervalSince($0.2) < 0.7 ? $0.0 : nil }
                    let mouth = validMouth ?? CGRect(x: box.midX, y: box.minY, width: 0, height: 0)
                    var tips: [CGPoint] = []
                    for hand in hands {
                        let points = try hand.recognizedPoints(.all)
                        for joint: VNHumanHandPoseObservation.JointName in [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip] {
                            if let p = points[joint], p.confidence >= 0.3 { tips.append(p.location) }
                        }
                    }
                    // Correct the x axis for image aspect ratio before calculating distance.
                    let aspect = analysisImage.extent.width / analysisImage.extent.height
                    let threshold = CGFloat(settings.sensitivity) * box.width * aspect
                    debugMouth = validMouth; debugTips = tips
                    debugZone = mouth.insetBy(dx: -threshold / aspect, dy: -threshold)
                    let mouthNear = validMouth != nil && tips.contains { p in
                        let dx = max(mouth.minX - p.x, 0, p.x - mouth.maxX) * aspect
                        let dy = max(mouth.minY - p.y, 0, p.y - mouth.maxY)
                        return hypot(dx, dy) < threshold
                    }
                    near = validMouth == nil ? nil : mouthNear
                    // No hand visible is a clear frame only while the face is visible.
                    if face == nil && tips.isEmpty { near = nil }
                    message = near == true ? "Fingers near mouth" : (validMouth == nil ? "Mouth not visible - check lighting and position" : "Monitoring - hands away from mouth")
                }
                let trigger = gate.update(near: near, at: date, hold: settings.hold, rearm: settings.rearm)
                // End an episode after prolonged loss of face; do not retain stale detections.
                if near == nil {
                    if unknownSince == nil { unknownSince = date }
                    if date.timeIntervalSince(unknownSince!) > 2 { gate = GestureGate() }
                } else { unknownSince = nil }
                var image: NSImage?
                let previewDue = preview && now - lastPreview >= 1 / settings.previewFPS
                if trigger || previewDue {
                    let ci = analysisImage
                    let scale = min(1, 640 / ci.extent.width)
                    let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    if let cg = context.createCGImage(small, from: small.extent) { image = NSImage(cgImage: cg, size: .zero) }
                    if previewDue { lastPreview = now }
                }
                let measuredFPS = previousTime > 0 ? 1 / (now - previousTime) : 0; previousTime = now
                let state = near == nil ? "Uncertain detection" : gate.active ? (near == true ? "Alert · episode active" : "Waiting for hands to move away") : near == true ? "Confirming gesture" : "No gesture"
                let debug = previewDue ? image.map { DebugFrame(image: $0, mouth: debugMouth, zone: debugZone, tips: debugTips, aspect: analysisImage.extent.width / analysisImage.extent.height) } : nil
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                analysisAverage = analysisAverage == 0 ? elapsed : analysisAverage * 0.85 + elapsed * 0.15
                result?(Detection(trigger: trigger, active: gate.active, message: message, near: near == true, phase: state, zones: "Mouth", camera: "\(CVPixelBufferGetWidth(buffer)) × \(CVPixelBufferGetHeight(buffer)) · analysis \(Int(analysisImage.extent.width.rounded())) × \(Int(analysisImage.extent.height.rounded()))", debug: debug, image: image, fps: measuredFPS, milliseconds: elapsed * 1000))
            } catch { result?(Detection(message: "Uncertain detection - \(error.localizedDescription)")); gate = GestureGate() }
        }
    }
}
final class InteractiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class OverlayManager {
    private var panels: [NSPanel] = []
    private var dismissal: DispatchWorkItem?
    private enum PersistentOverlay { case repeatingAlert, practice }
    private var persistentOverlay: PersistentOverlay?
    private var reusableCards: [NSPanel] = []
    private var reusableScreenFrames: [CGRect] = []
    private var reusableDim = 0.0

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        persistentOverlay = nil
        reusableCards.removeAll()
        reusableScreenFrames.removeAll()
    }

    func endRepeatingAlert(after duration: TimeInterval = 0) {
        guard persistentOverlay == .repeatingAlert else { return }
        if duration == 0 {
            hide()
            return
        }

        // Switch out of repeat mode so later camera frames cannot restart the dismissal clock.
        persistentOverlay = nil
        scheduleDismissal(after: duration)
    }

    private func scheduleDismissal(after duration: TimeInterval) {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
    private func panel(_ frame: CGRect, level: NSWindow.Level, interactive: Bool = false) -> NSPanel {
        let p = InteractiveOverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = level; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; p.ignoresMouseEvents = !interactive
        return p
    }
    private func fittedContent<Content: View>(_ content: Content, width: CGFloat, maxHeight: CGFloat) -> NSHostingView<AnyView> {
        let root = content.frame(width: width).fixedSize(horizontal: false, vertical: true).environment(\.locale, Locale(identifier: "en_US"))
        let host = NSHostingView(rootView: AnyView(root))
        let height = min(maxHeight, max(1, ceil(host.fittingSize.height)))
        if host.fittingSize.height > maxHeight {
            host.rootView = AnyView(ScrollView { root }.frame(width: width, height: height))
        }
        host.setFrameSize(NSSize(width: width, height: height))
        return host
    }
    func showPractice(training: PracticeController, image: NSImage?, settings: Settings, escalation: Int = 0) {
        let compact = training.overlayMinimized
        let position = compact ? settings.resolvedHRTDockPosition : settings.overlayPosition
        let photo = settings.overlayPhoto && settings.overlayStyle == "Card" ? image : nil
        let shouldDim = !compact && (training.phase == .active || training.phase == .offered)
        let width = compact ? 280 : scaledWidth(settings.overlayWidth, escalation: escalation)
        let accent = OverlayAccent(rawValue: settings.overlayAccent)?.color ?? .orange

        presentCards(settings: settings, kind: .practice, width: width, position: position, compact: compact,
                     dim: shouldDim ? settings.dim : 0) { width in
            PracticeOverlayView(training: training, accent: accent, width: width, image: photo,
                                banner: settings.overlayStyle == "Banner", compact: compact)
        }
    }

    func show(image: NSImage?, settings: Settings, escalation: Int = 0, repeating: Bool = false) {
        let accent = OverlayAccent(rawValue: settings.overlayAccent)?.color ?? .orange
        presentCards(settings: settings, kind: repeating ? .repeatingAlert : nil,
                     width: scaledWidth(settings.overlayWidth, escalation: escalation),
                     position: settings.overlayPosition, dim: settings.dim) { width in
            AlertView(image: image, style: settings.overlayStyle, width: width, accent: accent, escalation: escalation)
        }
        if !repeating { scheduleDismissal(after: settings.overlaySeconds) }
    }

    private func scaledWidth(_ width: Double, escalation: Int) -> CGFloat {
        CGFloat(width) * (1 + CGFloat(escalation) * 0.12)
    }

    private func presentCards<Content: View>(settings: Settings, kind: PersistentOverlay?, width: CGFloat,
                                             position: String, compact: Bool = false, dim: Double,
                                             content: (CGFloat) -> Content) {
        let available = NSScreen.screens
        let selected = available.filter {
            let screenID = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return settings.screenID == "all" || String(screenID) == settings.screenID
        }
        let screens = selected.isEmpty ? Array(available.prefix(1)) : selected
        let frames = screens.map(\.frame)
        let reuse = kind != nil && kind == persistentOverlay && !reusableCards.isEmpty
            && reusableScreenFrames == frames && reusableDim == dim
        if !reuse { hide() }

        for (index, screen) in screens.enumerated() {
            if !reuse && dim > 0 {
                let dimmer = panel(screen.frame, level: .floating)
                dimmer.backgroundColor = NSColor.black.withAlphaComponent(dim)
                dimmer.orderFrontRegardless()
                panels.append(dimmer)
            }
            let cardWidth = min(width, screen.visibleFrame.width - 48)
            let hosting = fittedContent(content(cardWidth), width: cardWidth, maxHeight: screen.visibleFrame.height - 48)
            let frame = practiceOverlayFrame(visible: screen.visibleFrame, size: hosting.frame.size,
                                             compact: compact, position: position, screen: screen.frame)
            if reuse {
                let card = reusableCards[index]
                card.contentView = hosting
                card.setFrame(frame, display: true)
            } else {
                let level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
                let card = panel(frame, level: level, interactive: kind == .practice)
                card.hasShadow = true
                card.contentView = hosting
                card.orderFrontRegardless()
                panels.append(card)
                if kind != nil { reusableCards.append(card) }
            }
        }

        persistentOverlay = kind
        reusableScreenFrames = frames
        reusableDim = dim
    }
}

struct AlertView: View {
    let image: NSImage?
    let style: String
    let width: CGFloat
    let accent: Color
    let escalation: Int
    private var padding: CGFloat { image == nil ? 18 + CGFloat(escalation) * 2 : 18 }
    var body: some View {
        Group {
            if style == "Card" {
                VStack(spacing: 12) {
                    Label("Move your hand away", systemImage: "hand.raised.fill").font(.title2.bold())
                    if let image {
                        let size = overlaySnapshotSize(image: image.size, width: width - 2 * padding)
                        Image(nsImage: image).resizable().scaledToFit().frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    else { Image(systemName: "hand.raised.slash.fill").font(.system(size: 90)).frame(height: 160 + CGFloat(escalation) * 8) }
                }.padding(padding).frame(maxWidth: .infinity)
            } else {
                Label("Hands away · take a breath", systemImage: "hand.raised.fill").font(.title3.bold()).padding(20 + CGFloat(escalation) * 4).frame(maxWidth: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent, lineWidth: 3)).clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
struct MainView: View {
    @ObservedObject var model: Model
    @ObservedObject var training: PracticeController
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Label("NailGuard", systemImage: "hand.raised.fill").font(.title2.bold())
                    Spacer()
                    Circle().fill(model.running ? .green : .gray).frame(width: 8, height: 8)
                    Text(model.running ? "Monitoring active" : "Paused").foregroundStyle(.secondary)
                    Button(model.running ? "Pause" : "Start") { model.running ? model.stop() : model.start() }.buttonStyle(.borderedProminent).disabled(model.dataBusy)
                }
                Picker("View", selection: $model.tab) {
                    Text("Monitoring").tag(0)
                    Text("Statistics").tag(1)
                    Text("HRT Practice").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }.padding(.horizontal, 20).frame(height: 64)
            Divider()
            if training.busy && model.tab != 2 {
                HStack {
                    Label(training.phase == .active ? "HRT Practice in progress · " + training.shortTime : training.phase == .offered ? "Ready to practise · start when you are ready" : "HRT timer finished · check in when ready", systemImage: "hands.sparkles")
                    Spacer()
                    Button("Open HRT Practice") { model.tab = 2 }
                }.padding(.horizontal, 20).padding(.vertical, 10).background(Color.accentColor.opacity(0.08))
            }
            Group {
                if model.tab == 0 { MonitorView(model: model) }
                else if model.tab == 2 { PracticeView(training: training, model: model) }
                else { StatisticsView(model: model, training: training) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.dataBusy)
        }.frame(minWidth: 1040, minHeight: 700)
    }
}
struct MonitorView: View {
    @ObservedObject var model: Model
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.status).font(.headline).textSelection(.enabled).frame(minHeight: 32, alignment: .leading)
                HStack {
                    Toggle("Camera preview", isOn: $model.previewEnabled)
                    Spacer(); Button("Test alert") { model.testAlert() }
                }
                ZStack {
                    Color.black.opacity(0.8)
                    if let frame = model.debugFrame {
                        CameraPreview(frame: frame).aspectRatio(frame.aspect, contentMode: .fit)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "video.slash").font(.system(size: 40))
                            Text(model.running ? "Preview disabled or waiting for a frame" : "Start monitoring to see the camera")
                        }.foregroundStyle(.white.opacity(0.75)).padding()
                    }
                }.frame(maxWidth: .infinity).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 12))
                Text(model.detectionState).font(.headline).foregroundStyle(.orange)
                Text("Green: mouth · orange: trigger boundary · cyan: fingertips. Preview is not mirrored.").font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack { Text("Today: \(model.today.count) episodes").font(.headline); Spacer() }
                PerformanceView(model: model)
                Text("Adjust the controls on the right while watching the preview. Changes apply immediately and save automatically.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(20).frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ControlsView(model: model, training: model.training).frame(minWidth: 490, idealWidth: 510, maxWidth: 600)
        }
    }
}
struct CameraPreview: View {
    let frame: DebugFrame
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(nsImage: frame.image).resizable()
                Canvas { context, size in
                    func rect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height) }
                    if let zone = frame.zone, let mouth = frame.mouth {
                        // Exact rounded distance boundary, matching the detector's Euclidean rule.
                        let radius = max(0, (mouth.minY - zone.minY) * size.height)
                        context.stroke(Path(roundedRect: rect(zone), cornerRadius: radius), with: .color(.orange), lineWidth: 2)
                    }
                    if let mouth = frame.mouth { context.stroke(Path(rect(mouth)), with: .color(.green), lineWidth: 2) }
                    for p in frame.tips {
                        let r = CGRect(x: p.x * size.width - 5, y: (1 - p.y) * size.height - 5, width: 10, height: 10)
                        context.fill(Path(ellipseIn: r), with: .color(.cyan))
                    }
                }
            }.frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
struct StatisticsView: View {
    @ObservedObject var model: Model
    @ObservedObject var training: PracticeController
    var data: StatisticsSummary { model.statistics }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Statistics").font(.title2.bold())
                    Spacer()
                    Picker("Range", selection: $model.statisticsRange) {
                        ForEach(["Today", "7 days", "30 days", "Custom"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 420)
                }
                if model.statisticsRange == "Custom" {
                    HStack(spacing: 20) {
                        DatePicker("From", selection: $model.statisticsStart, in: ...Date(), displayedComponents: .date)
                        DatePicker("Through", selection: $model.statisticsEnd, in: ...Date(), displayedComponents: .date)
                        Text("Both dates included").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 50) {
                    metric("Detected episodes", "\(data.acceptedCount)")
                    metric("Monitoring time", String(format: "%.0f min", data.monitored / 60))
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(data.window.hourly ? "Episodes by hour" : data.window.monthly ? "Episodes by month" : "Episodes by day").font(.headline)
                    Chart(data.bins) { bin in
                        BarMark(x: .value("Time", bin.date, unit: data.window.component), y: .value("Episodes", bin.count)).foregroundStyle(.orange)
                        if let date = model.hoveredBin, let bin = data.bins.first(where: { $0.date == date }) {
                            RuleMark(x: .value("Selected", bin.date, unit: data.window.component)).foregroundStyle(.orange.opacity(0.45))
                                .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(binLabel(bin)).font(.caption).foregroundStyle(.secondary)
                                        Text("\(bin.count) \(bin.count == 1 ? "detection" : "detections")").font(.headline)
                                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false)
                                }
                        }
                    }.chartOverlay { proxy in
                        GeometryReader { geometry in
                            Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard let anchor = proxy.plotFrame else { return }
                                    let plot = geometry[anchor]
                                    let date: Date? = plot.contains(location) ? proxy.value(atX: location.x - plot.minX) : nil
                                    let bin = date.flatMap { data.bin(containing: $0) }?.date
                                    if model.hoveredBin != bin { model.hoveredBin = bin }
                                case .ended: model.hoveredBin = nil
                                }
                            }
                        }
                    }.chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel(format: data.window.hourly ? .dateTime.hour() : data.window.monthly ? .dateTime.month(.abbreviated).year() : .dateTime.month(.abbreviated).day())
                        }
                    }.chartYScale(domain: 0...max(1, data.bins.map(\.count).max() ?? 1)).frame(height: 240)
                    Text("False alarms are excluded. Empty hours and days are included. Custom dates are inclusive; reversed dates are automatically ordered.").font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 12))
                PracticeStatistics(training: training, interval: data.window.interval)
                DisclosureGroup(isExpanded: $model.historyExpanded) {
                    eventHistory.padding(.top, 12)
                } label: {
                    HStack {
                        Label("Detection history", systemImage: "clock.arrow.circlepath").font(.headline)
                        Spacer(); Text("\(data.events.count) events in range").foregroundStyle(.secondary)
                    }
                }.padding(18).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 12))
                Text("Detects fingers near your mouth, not confirmed nail biting. Monitoring time includes fresh frames without a visible face. Photos remain local.").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
    func binLabel(_ bin: StatisticsBin) -> String {
        let locale = Locale(identifier: "en_US")
        if data.window.hourly {
            let end = Calendar.current.date(byAdding: .hour, value: 1, to: bin.date)!
            return bin.date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale)) + " - " + end.formatted(.dateTime.hour().minute().locale(locale))
        }
        return data.window.monthly ? bin.date.formatted(.dateTime.month(.wide).year().locale(locale)) : bin.date.formatted(.dateTime.month(.wide).day().year().locale(locale))
    }
    var eventHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("False alarm excludes an event from totals and charts. It keeps the event and photo; it does not train the detector.").font(.caption).foregroundStyle(.secondary)
            if data.events.isEmpty { Text("No events in this date range.").foregroundStyle(.secondary) }
            if data.events.count > 100 { Text("Showing the latest 100 of \(data.events.count) events. Narrow the date range to browse older events.").font(.caption).foregroundStyle(.secondary) }
            LazyVStack(spacing: 8) {
                ForEach(Array(data.events.suffix(100).reversed())) { event in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { model.expand(event) } label: {
                            HStack {
                                Image(systemName: model.expandedEvent == event.id ? "chevron.down" : "chevron.right").frame(width: 14)
                                Text(event.start.formatted(.dateTime.month(.abbreviated).day().hour().minute().second().locale(Locale(identifier: "en_US"))))
                                Spacer()
                                if event.falseAlarm { Text("False alarm").foregroundStyle(.secondary) }
                                Text(String(format: "%.0f s", event.duration)).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: event.snapshotFile == nil ? "photo.badge.exclamationmark" : "photo").foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if model.expandedEvent == event.id {
                            if let image = model.expandedImage { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 8)) }
                            else { Text(event.snapshotFile == nil ? "No snapshot was saved for this event." : "Loading snapshot, or photo no longer retained.").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Text(event.zones ?? "Mouth").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(event.falseAlarm ? "Restore event" : "Mark as false alarm") { model.markFalse(event.id) }
                            }
                        }
                    }.padding(12).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(value).font(.title.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}
struct ControlsView: View {
    @ObservedObject var model: Model
    @ObservedObject var training: PracticeController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Adjust", selection: $model.controlPage) {
                ForEach(["Detection", "Sound", "Overlay", "More"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.top, 12)
            Form {
                switch model.controlPage {
                case "Sound": alerts
                case "Overlay": overlay
                case "More": dataActions; storage; startup; reset
                default: detection; performance
                }
            }.formStyle(.grouped)
        }.onAppear { model.refreshScreens(); model.refreshLoginStatus() }
    }
    var reset: some View {
        Section("Defaults") {
            Button("Restore default settings") {
                model.settings = Settings()
                if training.available { training.preferences = PracticePreferences() }
            }.disabled(training.busy || training.resetting)
            Text("Settings save automatically. This does not delete history or change login registration.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var detection: some View {
        Section("Detection") {
            slider("Mouth sensitivity · fraction of face width", value: $model.settings.sensitivity, range: 0.08...0.35, step: 0.01)
            HStack { Text("Gesture confirmation"); Spacer(); Text(model.settings.hold == 0 ? "Instant" : String(format: "%.2f s", model.settings.hold)) }
            Slider(value: $model.settings.hold, in: 0...2, step: 0.05)
            Text("Instant alerts on the first matching analysed frame. Camera and analysis latency still apply; brief touches may trigger false alarms.").font(.caption).foregroundStyle(.secondary)
            slider("Hands-away time before next episode (s)", value: $model.settings.rearm, range: 0.3...4, step: 0.1)
            Text("Keep fingers away from the mouth for this long to allow a new alert. Brief withdrawals remain part of the same episode.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var alerts: some View {
        Section("Sound alerts") {
            Toggle("Enable sound", isOn: $model.settings.sound)
            Picker("Sound", selection: $model.settings.soundName) { ForEach(soundNames, id: \.self) { Text($0).tag($0) } }
            slider("Volume", value: $model.settings.volume, range: 0...1, step: 0.05)
            Toggle("Repeat while fingers remain near mouth", isOn: $model.settings.repeatAlarm)
            if model.settings.repeatAlarm {
                slider("Repeat interval (s)", value: $model.settings.repeatSeconds, range: 1...5, step: 1)
                Text("The alert grows and gets louder over the first three repeats, then stays at the highest level.").font(.caption).foregroundStyle(.secondary)
                if training.preferences.enabled {
                    Text("HRT repeats apply to camera invitations before you start the timer.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Test sound and overlay") { model.testAlert() }
        }
    }
    var overlay: some View {
        Section("Overlay") {
            if training.preferences.enabled && training.available {
                Text("HRT always shows its countdown overlay until the timer ends, independently of the ordinary overlay switch and duration. Card/Banner style, snapshots, position, dimming and display selection also apply to HRT. Docking removes dimming.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle(training.preferences.enabled ? "Show ordinary overlay when HRT is off" : "Show overlay", isOn: $model.settings.overlay)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("Accent color"); Spacer(); Text(model.settings.overlayAccent).foregroundStyle(.secondary) }
                HStack(spacing: 12) {
                    ForEach(OverlayAccent.allCases) { accent in
                        Button { model.settings.overlayAccent = accent.rawValue } label: {
                            Circle().fill(accent.color).frame(width: 22, height: 22).padding(4)
                                .overlay(Circle().strokeBorder(model.settings.overlayAccent == accent.rawValue ? Color.primary : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).help(accent.rawValue).accessibilityLabel(accent.rawValue)
                            .accessibilityValue(model.settings.overlayAccent == accent.rawValue ? "Selected" : "Not selected")
                    }
                }
            }
            Picker("Style", selection: $model.settings.overlayStyle) { ForEach(["Card", "Banner"], id: \.self) { Text($0).tag($0) } }
            Toggle("Include snapshot · Card style", isOn: $model.settings.overlayPhoto)
            slider(training.preferences.enabled ? "Ordinary alert duration (s)" : "Duration (s)", value: $model.settings.overlaySeconds, range: 1...10, step: 0.5)
            if model.settings.repeatAlarm && !training.preferences.enabled {
                Text("With repeats enabled, this time starts when you move your hand away.").font(.caption).foregroundStyle(.secondary)
            }
            slider("Width (points)", value: $model.settings.overlayWidth, range: 280...640, step: 20)
            Picker("Position", selection: $model.settings.overlayPosition) { ForEach(Settings.overlayPositions, id: \.self) { Text($0).tag($0) } }
            slider("Background dimming", value: $model.settings.dim, range: 0...0.75, step: 0.05)
            Text("Dimming applies to selected displays for the alert duration. It does not intercept clicks or change display brightness.").font(.caption).foregroundStyle(.secondary)
            Picker("Display", selection: $model.settings.screenID) {
                Text("All displays").tag("all")
                ForEach(model.screens, id: \.0) { screen in Text(screen.1).tag(screen.0) }
                if model.settings.screenID != "all" && !model.screens.contains(where: { $0.0 == model.settings.screenID }) { Text("Disconnected display · use available display").tag(model.settings.screenID) }
            }
            Button("Refresh displays") { model.refreshScreens() }
            Button("Preview overlay") { model.testAlert() }
        }
    }
    var performance: some View {
        Section("Camera & processing") {
            HStack { Text("Presets"); Spacer(); ForEach(["Eco", "Balanced", "Detail"], id: \.self) { name in Button(name) { model.profile(name) } } }
            Text("Eco: 480p / 3 fps · Balanced: 720p / 6 fps · Detail: 1080p / 10 fps. Choose Eco first; higher resolutions mainly help smaller, more distant hands.").font(.caption).foregroundStyle(.secondary)
            Picker("Processing resolution", selection: $model.settings.resolution) { ForEach(["640 × 480", "1280 × 720", "1920 × 1080"], id: \.self) { Text($0).tag($0) } }
            slider("Analysis fps · target", value: $model.settings.analysisFPS, range: 2...15, step: 1)
            slider("Preview fps · maximum", value: $model.settings.previewFPS, range: 1...10, step: 1)
            Toggle("Adaptive load control", isOn: $model.settings.adaptive)
            Toggle("Efficient face updates · up to 3 fps", isOn: $model.settings.efficientFaceUpdates)
            Text("Face landmarks update at up to 3 fps; finger checks keep the analysis rate. Turn this off for rapid head movements. Preview adds image conversion and rendering work; disabling it keeps detection active.").font(.caption).foregroundStyle(.secondary)
            Text("Adaptive mode reduces analysis to 2 fps after 3 seconds without a face and leaves processing headroom. Actual rates may be lower than targets. Preview is capped at 640 px and stops when hidden. No video is recorded.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var storage: some View {
        Section("History & privacy") {
            Toggle("Save local event snapshots", isOn: $model.settings.saveSnapshots)
            slider("Snapshot retention (days)", value: $model.settings.snapshotDays, range: 1...90, step: 1)
            slider("Maximum saved snapshots", value: $model.settings.snapshotLimit, range: 50...1000, step: 50)
            Text("Photos stay on this Mac. Limits remove older photos but keep event metadata. Turning saving off keeps existing files until their retention limit.").font(.caption).foregroundStyle(.secondary)
            Button("Open local data folder") { NSWorkspace.shared.open(model.snapshotsURL.deletingLastPathComponent()) }
        }
    }
    var dataActions: some View {
        Section("Manage data") {
            Button("Reset detection statistics...", role: .destructive) { model.confirmDataAction(.resetStatistics) }
            Text("Clear detection history and monitored time. Saved photos and practice statistics are kept.").font(.caption).foregroundStyle(.secondary)
            Button("Delete snapshots...", role: .destructive) { model.confirmDataAction(.deleteSnapshots) }
            Text("Move saved event photos to Trash. Keep detection history and totals.").font(.caption).foregroundStyle(.secondary)
            if !model.dataMessage.isEmpty { Text(model.dataMessage).font(.caption).textSelection(.enabled) }
        }
    }
    var startup: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            Text(model.loginStatus).font(.caption).foregroundStyle(.secondary)
            Button("Refresh login status") { model.refreshLoginStatus() }
            Toggle("Start monitoring when the app opens", isOn: $model.settings.autoMonitor)
            Toggle("Resume monitoring after unlock", isOn: $model.settings.resumeAfterUnlock)
            Text("Monitoring on launch activates the camera. Lock and sleep stop capture. Automatic resume applies only if monitoring was active before the interruption; manual pause stays paused.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) { HStack { Text(title); Spacer(); Text(String(format: step >= 1 ? "%.0f" : step >= 0.1 ? "%.1f" : "%.2f", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary) }; Slider(value: value, in: range, step: step) }
    }
}
struct PerformanceView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(format: "%.1f fps · %.0f ms/frame · CPU %.1f%%", model.fps, model.latency, model.cpu)).monospacedDigit()
                .help("CPU is averaged over about 2 seconds. 100% means one CPU core. GPU and Neural Engine energy are not included. Frame time is processing time, not total alert latency.")
            Text("100% CPU = one fully used core").font(.caption).foregroundStyle(.secondary)
            Text(model.running ? "Camera: \(model.actualCamera)" : "Camera off").font(.caption).foregroundStyle(.secondary)
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    var window: NSWindow!
    var item: NSStatusItem!
    private var practiceHotKey: EventHotKeyRef?
    private var practiceHandler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.delegate = self; window.title = "NailGuard HRT" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { " " + $0 } ?? ""); window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: MainView(model: model, training: model.training).environment(\.locale, Locale(identifier: "en_US"))); window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "NailGuard")
        item.button?.toolTip = "NailGuard HRT"
        item.button?.setAccessibilityLabel("NailGuard")
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open NailGuard HRT", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = NSMenu()
        let quit = NSMenuItem(title: "Quit NailGuard", action: #selector(quit), keyEquivalent: "q"); quit.target = self; root.submenu?.addItem(quit); appMenu.addItem(root); NSApp.mainMenu = appMenu
        registerPracticeShortcut()
        openWindow()
        if model.settings.autoMonitor { model.start() }
    }
    func windowWillClose(_ notification: Notification) { model.windowVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { model.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowVisible = true }
    @objc func openWindow() { model.windowVisible = true; if window.isMiniaturized { window.deminiaturize(nil) }; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func openPractice() { model.tab = 2; openWindow() }
    @objc func noticedUrge() {
        guard model.training.preferences.enabled && model.training.available else { openPractice(); return }
        model.training.manual(.noticed)
    }
    private func registerPracticeShortcut() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            owner.noticedUrge()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &practiceHandler)
        guard status == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x4E474852, id: 1)
        model.training.shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &practiceHotKey) == noErr
    }
    @objc func quit() {
        guard !model.dataBusy else { model.dataMessage = "Please wait for the data operation to finish before quitting."; openWindow(); return }
        model.stop(); NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.dataBusy ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.training.end(); model.training.flush(); model.flush()
        if let practiceHotKey { UnregisterEventHotKey(practiceHotKey) }
        if let practiceHandler { RemoveEventHandler(practiceHandler) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
if CommandLine.arguments.contains("--self-test") {
    var g = GestureGate(); let t = Date(timeIntervalSince1970: 0)
    precondition(!g.update(near: true, at: t, hold: 0.6))
    precondition(g.update(near: true, at: t.addingTimeInterval(0.7), hold: 0.6))
    precondition(!g.update(near: true, at: t.addingTimeInterval(1), hold: 0.6))
    precondition(!g.update(near: false, at: t.addingTimeInterval(2), hold: 0.6))
    precondition(!g.update(near: false, at: t.addingTimeInterval(3.3), hold: 0.6)); precondition(!g.active)
    precondition(!g.update(near: true, at: t.addingTimeInterval(4), hold: 0.6))
    precondition(!g.update(near: nil, at: t.addingTimeInterval(4.5), hold: 0.6))
    precondition(!g.update(near: true, at: t.addingTimeInterval(5), hold: 0.6))
    var custom = GestureGate()
    precondition(!custom.update(near: true, at: t, hold: 0.3, rearm: 3))
    precondition(custom.update(near: true, at: t.addingTimeInterval(0.4), hold: 0.3, rearm: 3))
    _ = custom.update(near: false, at: t.addingTimeInterval(1), hold: 0.3, rearm: 3)
    _ = custom.update(near: false, at: t.addingTimeInterval(3), hold: 0.3, rearm: 3)
    precondition(custom.active)
    _ = custom.update(near: false, at: t.addingTimeInterval(4.1), hold: 0.3, rearm: 3)
    precondition(!custom.active)
    var settings = Settings(); settings.volume = 0.25; settings.analysisFPS = 3; settings.overlayPosition = "Bottom"
    precondition(try! JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    var instant = GestureGate()
    precondition(instant.update(near: true, at: t, hold: 0))
    precondition(!instant.update(near: true, at: t.addingTimeInterval(0.1), hold: 0))
    let oldSettings = Data(#"{"sensitivity":0.27,"hold":0.1,"overlayPosition":"Dół","repeatAlarm":true}"#.utf8)
    let migrated = Settings.load(oldSettings)
    precondition(migrated.sensitivity == 0.27 && migrated.hold == 0.1 && migrated.overlayPosition == "Bottom" && migrated.repeatAlarm && migrated.saveSnapshots)
    precondition(Settings.load(nil).saveSnapshots)
    precondition(Settings.load(Data(#"{"saveSnapshots":true}"#.utf8)).saveSnapshots)
    precondition(!Settings.load(Data(#"{"saveSnapshots":false}"#.utf8)).saveSnapshots)
    let oldEpisode = Data(#"{"id":"00000000-0000-0000-0000-000000000001","start":0,"duration":1,"falseAlarm":true}"#.utf8)
    let legacy = try! JSONDecoder().decode(Episode.self, from: oldEpisode)
    precondition(legacy.falseAlarm && legacy.snapshotFile == nil && legacy.zones == nil)
    let compactSettings = Settings.load(Data(#"{"overlayStyle":"Compact","mouth":false,"hair":true,"custom":true}"#.utf8))
    precondition(compactSettings.overlayStyle == "Card" && compactSettings.overlayAccent == "Red")
    precondition(compactSettings.hrtCheckIn && compactSettings.hrtFinishSound == "Ping")
    precondition(Settings.load(Data(#"{"hrtCheckIn":false,"hrtFinishSound":"None","hrtFinishVolume":9}"#.utf8)).hrtFinishVolume == 1)
    precondition(Settings.load(Data(#"{"overlayAccent":"Blue"}"#.utf8)).overlayAccent == "Blue")
    precondition(Settings.load(Data(#"{"overlayAccent":"unknown"}"#.utf8)).overlayAccent == Settings().overlayAccent)
    try! testPractice()
    try! testAlertRepeats()
    testMonitoringResume()
    testAppArtwork()
    testStatistics()
    testFramePacer()
    testAnalysisImage()
    try! testDataManagement()
    let encodedEpisode = try! JSONEncoder().encode(legacy)
    precondition(try! JSONDecoder().decode(Episode.self, from: encodedEpisode).falseAlarm)
    precondition(CPUMeter().sample().isFinite)
    print("PASS: lock/wake resume policy and icon resources; data reset and photo removal isolation, simulated deletion failure; instant, old settings/history migration, inclusive date ranges, hourly bins, compact migration, CPU sample; settings round-trip, custom rearm; sustained gesture, duplicate suppression, clear rearm, missing observation")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate(); app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
}
