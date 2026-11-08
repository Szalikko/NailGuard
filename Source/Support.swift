import Cocoa
import AVFoundation
import CoreImage
import ImageIO
import Darwin

final class CPUMeter {
    private var lastCPU: Double
    private var lastWall: Double
    init() { lastCPU = Self.seconds(); lastWall = ProcessInfo.processInfo.systemUptime }
    private static func seconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func sample() -> Double {
        let cpu = Self.seconds(); let wall = ProcessInfo.processInfo.systemUptime
        defer { lastCPU = cpu; lastWall = wall }
        return max(0, (cpu - lastCPU) / max(0.001, wall - lastWall) * 100)
    }
}
func cameraPreset(_ resolution: String) -> AVCaptureSession.Preset {
    switch resolution { case "1920 × 1080": return .hd1920x1080; case "1280 × 720": return .hd1280x720; default: return .vga640x480 }
}
let soundNames: [String] = {
    let folder = URL(fileURLWithPath: "/System/Library/Sounds")
    let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { ["aiff", "wav", "caf"].contains($0.pathExtension.lowercased()) }.map { $0.deletingPathExtension().lastPathComponent }
    return Array(Set(found + ["Glass", "Ping", "Pop", "Sosumi", "Submarine"])).sorted()
}()

struct StatisticsWindow {
    var interval: DateInterval
    var hourly: Bool
    var monthly: Bool
    var component: Calendar.Component { hourly ? .hour : monthly ? .month : .day }
    static func make(range: String, from: Date, through: Date, now: Date, calendar: Calendar = .current) -> StatisticsWindow {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        var start = today
        var end = tomorrow
        switch range {
        case "7 days": start = calendar.date(byAdding: .day, value: -6, to: today)!
        case "30 days": start = calendar.date(byAdding: .day, value: -29, to: today)!
        case "Custom":
            let lower = min(from, through), upper = max(from, through)
            start = calendar.startOfDay(for: max(Date(timeIntervalSince1970: 0), min(lower, now)))
            let upperDay = calendar.startOfDay(for: max(Date(timeIntervalSince1970: 0), min(upper, now)))
            end = calendar.date(byAdding: .day, value: 1, to: upperDay)!
        default: break
        }
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 1
        return StatisticsWindow(interval: DateInterval(start: start, end: end), hourly: days == 1, monthly: days > 366)
    }
    func contains(_ date: Date) -> Bool { date >= interval.start && date < interval.end }
}
struct StatisticsBin: Identifiable {
    var date: Date
    var count: Int
    var id: Date { date }
}
struct StatisticsSummary {
    var window: StatisticsWindow
    var bins: [StatisticsBin]
    var events: [Episode]
    var acceptedCount: Int
    var falseCount: Int
    var monitored: Double
    func bin(containing date: Date, calendar: Calendar = .current) -> StatisticsBin? {
        guard window.contains(date), let start = calendar.dateInterval(of: window.component, for: date)?.start else { return nil }
        return bins.first { $0.date == start }
    }
    static var empty: StatisticsSummary {
        StatisticsSummary(window: .make(range: "Today", from: Date(), through: Date(), now: Date()), bins: [], events: [], acceptedCount: 0, falseCount: 0, monitored: 0)
    }
}
func calendarDayKey(_ date: Date, calendar: Calendar) -> String {
    let p = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
}
func summarize(history: History, window: StatisticsWindow, calendar: Calendar = .current) -> StatisticsSummary {
    let events = history.episodes.filter { window.contains($0.start) }.sorted { $0.start < $1.start }
    let accepted = events.filter { !$0.falseAlarm }
    var counts: [Date: Int] = [:]
    for event in accepted {
        if let bucket = calendar.dateInterval(of: window.component, for: event.start)?.start { counts[bucket, default: 0] += 1 }
    }
    var bins: [StatisticsBin] = []
    var cursor = calendar.dateInterval(of: window.component, for: window.interval.start)?.start ?? window.interval.start
    while cursor < window.interval.end {
        bins.append(StatisticsBin(date: cursor, count: counts[cursor] ?? 0))
        guard let next = calendar.date(byAdding: window.component, value: 1, to: cursor), next > cursor else { break }
        cursor = next
    }
    let startKey = calendarDayKey(window.interval.start, calendar: calendar), endKey = calendarDayKey(window.interval.end, calendar: calendar)
    let monitored = history.monitored.filter { $0.key >= startKey && $0.key < endKey }.values.reduce(0, +)
    return StatisticsSummary(window: window, bins: bins, events: events, acceptedCount: accepted.count, falseCount: events.count - accepted.count, monitored: monitored)
}
func testStatistics() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
    let now = date(2026, 11, 8, 18)
    let today = StatisticsWindow.make(range: "Today", from: now, through: now, now: now, calendar: cal)
    precondition(today.hourly && today.contains(date(2026, 11, 8)) && !today.contains(date(2026, 11, 9)))
    let custom = StatisticsWindow.make(range: "Custom", from: date(2026, 11, 6), through: date(2026, 11, 8), now: now, calendar: cal)
    let reversed = StatisticsWindow.make(range: "Custom", from: date(2026, 11, 8), through: date(2026, 11, 6), now: now, calendar: cal)
    precondition(custom.interval == reversed.interval && custom.contains(date(2026, 11, 8, 23)) && !custom.contains(date(2026, 11, 9)))
    var h = History()
    h.episodes = [Episode(start: date(2026, 11, 8, 9), duration: 1), Episode(start: date(2026, 11, 8, 9), duration: 2, falseAlarm: true), Episode(start: date(2026, 11, 7, 23), duration: 1), Episode(start: date(2026, 11, 9), duration: 1)]
    h.monitored = ["2026-11-08": 3600, "2026-11-07": 1800, "2026-11-09": 60]
    let summary = summarize(history: h, window: today, calendar: cal)
    precondition(summary.bin(containing: date(2026, 11, 8, 9), calendar: cal)?.count == 1)
    precondition(summary.bin(containing: date(2026, 11, 9), calendar: cal) == nil)
    precondition(summary.bins.count == 24 && summary.acceptedCount == 1 && summary.falseCount == 1 && summary.monitored == 3600)
    precondition(summary.bins.reduce(0) { $0 + $1.count } == 1 && summary.bins[9].count == 1)
    let multi = summarize(history: h, window: custom, calendar: cal)
    precondition(multi.bins.count == 3 && multi.acceptedCount == 2 && multi.monitored == 5400)
    for (month, day, expected) in [(3, 29, 23), (10, 25, 25)] {
        let day = date(2026, month, day, 12)
        let window = StatisticsWindow.make(range: "Today", from: day, through: day, now: day, calendar: cal)
        precondition(summarize(history: History(), window: window, calendar: cal).bins.count == expected)
    }
    let long = StatisticsWindow.make(range: "Custom", from: date(2020, 1, 1), through: now, now: now, calendar: cal)
    precondition(long.monthly && summarize(history: History(), window: long, calendar: cal).bins.count < 100)
}

// Work on the latest frame only, preserving cadence without accumulating a frame queue.
struct FramePacer {
    private var deadline: Double?
    mutating func admit(now: Double, interval: Double) -> Bool {
        if let deadline, now + 0.002 < deadline { return false }
        deadline = max((deadline ?? now) + interval, now + interval * 0.5)
        return true
    }
}
func testFramePacer() {
    var pacer = FramePacer()
    var count = 0
    for i in 0..<720 { if pacer.admit(now: Double(i) / 12, interval: 1 / 6) { count += 1 } }
    precondition((359...361).contains(count))
    precondition(pacer.admit(now: 120, interval: 1 / 6))
    precondition(!pacer.admit(now: 120.001, interval: 1 / 6))
}

func captureDimensions(_ resolution: String) -> CMVideoDimensions {
    switch resolution {
    case "1920 × 1080": return CMVideoDimensions(width: 1920, height: 1080)
    case "1280 × 720": return CMVideoDimensions(width: 1280, height: 720)
    default: return CMVideoDimensions(width: 640, height: 480)
    }
}

func imageForAnalysis(_ source: CIImage, resolution: String) -> CIImage {
    let dimensions = captureDimensions(resolution)
    let ratio = CGFloat(dimensions.width) / CGFloat(dimensions.height)
    let bounds = source.extent
    let cropWidth = min(bounds.width, bounds.height * ratio)
    let cropHeight = cropWidth / ratio
    let crop = CGRect(x: bounds.midX - cropWidth / 2, y: bounds.midY - cropHeight / 2, width: cropWidth, height: cropHeight)
    let scale = min(1, CGFloat(dimensions.width) / cropWidth)
    return source.cropped(to: crop)
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
}
func testAnalysisImage() {
    let source = CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    for resolution in ["640 × 480", "1280 × 720", "1920 × 1080"] {
        let result = imageForAnalysis(source, resolution: resolution)
        let target = captureDimensions(resolution)
        precondition(abs(result.extent.width - CGFloat(target.width)) < 0.01)
        precondition(abs(result.extent.height - CGFloat(target.height)) < 0.01)
        precondition(abs(result.extent.minX) < 0.01 && abs(result.extent.minY) < 0.01)
    }
}

enum DataAction {
    case resetStatistics, deleteSnapshots
    var title: String { self == .resetStatistics ? "Reset all statistics?" : "Delete all saved snapshots?" }
    var button: String { self == .resetStatistics ? "Reset statistics" : "Delete snapshots" }
    var explanation: String {
        self == .resetStatistics
            ? "This permanently clears detection history and monitored-time totals. Saved snapshot files and your settings are kept. Monitoring will pause."
            : "Saved event photos will be moved to Trash and removed from event details. Detection history, totals and settings are kept. Monitoring will pause. You can recover the files from Trash."
    }
}
enum SnapshotStorageError: LocalizedError {
    case metadataAfterTrash(Error)
    var errorDescription: String? {
        switch self {
        case .metadataAfterTrash(let error): return "Photos were moved to Trash, but event references could not be saved: " + error.localizedDescription
        }
    }
}
struct LocalDataStore {
    let root: URL
    var historyURL: URL { root.appendingPathComponent("history.json") }
    var photosURL: URL { root.appendingPathComponent("Snapshots", isDirectory: true) }
    func write(_ history: History) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
    }
    func resetStatistics() throws -> History {
        let empty = History()
        try write(empty)
        return empty
    }
    func deleteSnapshots(history: History, trash: ((URL) throws -> Void)? = nil) throws -> History {
        let hadPhotos = FileManager.default.fileExists(atPath: photosURL.path)
        if hadPhotos {
            if let trash { try trash(photosURL) }
            else { try FileManager.default.trashItem(at: photosURL, resultingItemURL: nil) }
        }
        var updated = history
        for i in updated.episodes.indices { updated.episodes[i].snapshotFile = nil }
        do { try write(updated) }
        catch { if hadPhotos { throw SnapshotStorageError.metadataAfterTrash(error) }; throw error }
        return updated
    }
}
func testDataManagement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NailGuard-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalDataStore(root: root)
    try FileManager.default.createDirectory(at: store.photosURL, withIntermediateDirectories: true)
    let photo = store.photosURL.appendingPathComponent("test.jpg")
    try Data([1, 2, 3]).write(to: photo)
    var history = History()
    history.episodes = [Episode(start: Date(), duration: 2, falseAlarm: true, snapshotFile: "test.jpg")]
    history.monitored = ["2026-11-08": 3600]
    try store.write(history)
    let reset = try store.resetStatistics()
    precondition(reset.episodes.isEmpty && reset.monitored.isEmpty && FileManager.default.fileExists(atPath: photo.path))
    try store.write(history)
    enum TestError: Error { case blocked }
    do {
        _ = try store.deleteSnapshots(history: history) { _ in throw TestError.blocked }
        preconditionFailure("Failure must propagate")
    } catch TestError.blocked { }
    let unchanged = try JSONDecoder().decode(History.self, from: Data(contentsOf: store.historyURL))
    precondition(unchanged.episodes[0].snapshotFile == "test.jpg")
    let deleted = try store.deleteSnapshots(history: history) { url in
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("TestTrash"))
    }
    precondition(!FileManager.default.fileExists(atPath: photo.path))
    precondition(deleted.episodes.count == 1 && deleted.episodes[0].snapshotFile == nil && deleted.episodes[0].falseAlarm)
    precondition(deleted.monitored == history.monitored)
    let again = try store.deleteSnapshots(history: deleted) { _ in preconditionFailure("No photos remain") }
    precondition(again.episodes.count == 1)
    let failureStore = LocalDataStore(root: root.appendingPathComponent("Failure"))
    try FileManager.default.createDirectory(at: failureStore.photosURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: failureStore.historyURL, withIntermediateDirectories: true)
    do {
        _ = try failureStore.deleteSnapshots(history: history) { url in
            try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("SecondTestTrash"))
        }
        preconditionFailure("Must report partial metadata failure")
    } catch SnapshotStorageError.metadataAfterTrash { }
    let invalid = Settings.load(Data(#"{"rearm":-1,"snapshotLimit":-10,"dim":20,"resolution":"bad"}"#.utf8))
    precondition(invalid.rearm == 0.3 && invalid.snapshotLimit == 50 && invalid.dim == 0.75 && invalid.resolution == "640 × 480")
}

struct MonitoringResumeState {
    enum Reason { case screenLock, systemSleep }
    private var locked = false
    private var asleep = false
    private var pending = false
    private var unlockedSinceSuspension = false
    var isSuspended: Bool { locked || asleep }
    mutating func suspend(_ reason: Reason, wasRunning: Bool) {
        if !isSuspended { unlockedSinceSuspension = false }
        if reason == .screenLock { locked = true; unlockedSinceSuspension = false } else { asleep = true }
        if wasRunning { pending = true }
    }
    mutating func release(_ reason: Reason, enabled: Bool) -> Bool {
        if reason == .screenLock { locked = false; unlockedSinceSuspension = true } else { asleep = false }
        guard !isSuspended else { return false }
        guard enabled else { pending = false; return false }
        guard unlockedSinceSuspension else { return false }
        defer { pending = false }
        return pending
    }
    mutating func cancel() { pending = false }
}
func testAppArtwork() {
    precondition(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true)
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        preconditionFailure("Bundled app icon must decode")
    }
    precondition(image.width > 0 && image.height > 0)
}
func testMonitoringResume() {
    var state = MonitoringResumeState()
    state.suspend(.screenLock, wasRunning: true)
    precondition(state.isSuspended)
    state.suspend(.systemSleep, wasRunning: false)
    precondition(!state.release(.systemSleep, enabled: true))
    precondition(state.release(.screenLock, enabled: true))
    precondition(!state.release(.screenLock, enabled: true))
    state.suspend(.screenLock, wasRunning: true)
    state.suspend(.systemSleep, wasRunning: false)
    precondition(!state.release(.screenLock, enabled: true))
    precondition(state.release(.systemSleep, enabled: true))
    state.suspend(.screenLock, wasRunning: false)
    precondition(!state.release(.screenLock, enabled: true))
    state.suspend(.screenLock, wasRunning: true)
    precondition(!state.release(.screenLock, enabled: false))
    precondition(!state.release(.screenLock, enabled: true))
    state.suspend(.screenLock, wasRunning: true)
    state.cancel()
    precondition(!state.release(.screenLock, enabled: true))
    state.suspend(.systemSleep, wasRunning: true)
    precondition(!state.release(.systemSleep, enabled: true))
    precondition(state.release(.screenLock, enabled: true))
    precondition(Settings.load(nil).resumeAfterUnlock == false)
}
