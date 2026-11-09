import Cocoa
import SwiftUI

enum OverlayAccent: String, CaseIterable, Identifiable {
    case orange = "Orange", blue = "Blue", teal = "Teal", green = "Green", purple = "Purple", pink = "Pink", red = "Red"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .orange: return .orange
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        }
    }
}

enum PracticeResponse: String, Codable, CaseIterable, Identifiable {
    case fists = "Relaxed fists"
    case palms = "Palms on thighs"
    var id: String { rawValue }
    var instruction: String {
        switch self {
        case .fists: return "Lower your hands and gently close them into loose fists. Keep them comfortably away from your mouth."
        case .palms: return "Lower your hands and rest your palms flat on your thighs. Keep them still with gentle, comfortable contact."
        }
    }
}
struct PracticePreferences: Codable, Equatable {
    var enabled = false
    var response = PracticeResponse.fists
    var seconds = 60
    var cooldown = 0
}
enum PracticeSource: String, Codable { case camera = "Camera reminder", noticed = "Self-noticed urge", rehearsal = "Planned practice" }
enum PracticeOutcome: String, Codable { case completed = "Practised", interrupted = "Stopped early", dismissed = "Reminder dismissed", unconfirmed = "Timer finished, unconfirmed" }
enum UrgeChange: String, Codable, CaseIterable { case less = "Less", same = "Same", more = "More", unsure = "Not sure" }
enum PracticeTrigger: String, Codable, CaseIterable { case unsure = "Not sure", focus = "Focused work", tension = "Tension", boredom = "Boredom", edge = "Rough nail or skin" }
struct PracticeEvent: Codable, Identifiable {
    var id: UUID
    var date: Date
    var source: PracticeSource
    var response: PracticeResponse
    var target: Int
    var elapsed: Int
    var outcome: PracticeOutcome
    var change: UrgeChange?
    var urgeBefore: Int?
    var urgeAfter: Int?
    var trigger: PracticeTrigger?
}
struct PracticeDocument: Codable {
    var version = 1
    var preferences = PracticePreferences()
    var events: [PracticeEvent] = []
    mutating func resetHistory() { events.removeAll() }
    mutating func normalize() {
        preferences.seconds = [60, 90, 120].contains(preferences.seconds) ? preferences.seconds : 60
        preferences.cooldown = [0, 60, 120, 300, 600].contains(preferences.cooldown) ? preferences.cooldown : PracticePreferences().cooldown
        events = Array(events.suffix(5000))
    }
}

// Monotonic timing prevents clock changes from completing or extending a practice.
struct PracticeClock {
    let start: Double
    let duration: Int
    func elapsed(at uptime: Double) -> Int { min(duration, max(0, Int((uptime - start).rounded(.down)))) }
    func remaining(at uptime: Double) -> Int { max(0, duration - elapsed(at: uptime)) }
}
enum PracticePhase { case idle, offered, active, review }

final class PracticeController: NSObject, ObservableObject {
    var onInteraction: (() -> Void)?
    var onPresent: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onFinish: (() -> Void)?
    var checkInEnabled = true { didSet { if !checkInEnabled && phase == .review { end() } } }
    var autoDock = false
    @Published private(set) var overlayMinimized = false
    @Published var shortcutAvailable = false
    @Published private(set) var resetting = false
    @Published var historyExpanded = false
    @Published var preferences = PracticePreferences() {
        didSet {
            guard !loading else { return }
            if oldValue.enabled && !preferences.enabled { end(.interrupted) }
            persist()
        }
    }
    @Published private(set) var events: [PracticeEvent] = []
    @Published private(set) var phase = PracticePhase.idle
    @Published private(set) var remaining = 60
    @Published private(set) var sessionResponse = PracticeResponse.fists
    @Published private(set) var sessionDuration = 60
    @Published private(set) var sessionSource = PracticeSource.noticed
    @Published var change = UrgeChange.unsure
    @Published var trigger = PracticeTrigger.unsure
    @Published private(set) var message = ""
    private var loading = true
    private var readable = true
    private let folder: URL
    private let disk = DispatchQueue(label: "NailGuard.HRT.storage", qos: .utility)
    private var clock: PracticeClock?
    private var sessionID: UUID?
    private var sessionDate = Date()
    private var offeredAt = 0.0
    private var reviewStarted = 0.0
    private var autoDockHandled = false
    private var lastOffer = -Double.infinity
    private var document: PracticeDocument { PracticeDocument(preferences: preferences, events: events) }
    var cameraOfferPending: Bool { phase == .offered && sessionSource == .camera }
    var busy: Bool { phase == .offered || phase == .active }
    var available: Bool { readable && !AppMode.screenshot && !resetting }
    var shortTime: String { String(format: "%d:%02d", remaining / 60, remaining % 60) }
    var progress: Double { Double(sessionDuration - remaining) / Double(max(1, sessionDuration)) }
    init(folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NailGuard-HRT")) {
        self.folder = folder
        super.init()
        let url = folder.appendingPathComponent("practice.json")
        if !AppMode.screenshot && FileManager.default.fileExists(atPath: url.path) {
            do {
                var value = try JSONDecoder().decode(PracticeDocument.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                value.normalize(); preferences = value.preferences; events = value.events
            } catch {
                readable = false
                message = "Practice data could not be read. The file is preserved. Restore practice.json in the local data folder before using HRT."
            }
        }
        loading = false
    }
    private func persist() {
        guard available else { return }
        let value = document, url = folder.appendingPathComponent("practice.json")
        disk.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: url, options: .atomic)
            } catch { DispatchQueue.main.async { self?.message = "Could not save practice data: \(error.localizedDescription)" } }
        }
    }
    func flush() { disk.sync {} }
    func offerFromCamera(at uptime: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard preferences.enabled && available && !busy && uptime - lastOffer >= Double(preferences.cooldown) else { return false }
        prepare(.camera); lastOffer = uptime; offeredAt = uptime; phase = .offered; present()
        return true
    }
    func manual(_ source: PracticeSource, at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard preferences.enabled && available else { return }
        if busy { present(); return }
        prepare(source); offeredAt = uptime; phase = .offered; present()
    }
    private func prepare(_ source: PracticeSource) {
        sessionID = UUID(); sessionDate = Date(); sessionSource = source
        sessionResponse = preferences.response; sessionDuration = preferences.seconds; remaining = sessionDuration
        change = .unsure; trigger = .unsure; overlayMinimized = false; autoDockHandled = false
    }
    func startPractice(at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard phase == .offered, sessionID != nil else { return }
        clock = PracticeClock(start: uptime, duration: sessionDuration); phase = .active
        onInteraction?()
        onPresent?()
    }
    func tick(at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        if phase == .offered && uptime - offeredAt >= 30 { end(at: uptime); return }
        if phase == .review && uptime - reviewStarted >= 120 { end(at: uptime); return }
        guard phase == .active, let clock else { return }
        let left = clock.remaining(at: uptime)
        if remaining != left { remaining = left }
        if left == 0 {
            phase = .review; reviewStarted = uptime
            record(.unconfirmed)
            lastOffer = uptime
            overlayMinimized = false
            onFinish?()
            if checkInEnabled { onPresent?() }
            else { clearSession(beginCooldown: false) }
            // Never claim that a finished timer means the response was performed.
        } else if autoDock && !autoDockHandled && !overlayMinimized && sessionDuration - left >= 5 {
            minimizeOverlay()
        }
    }
    func confirmPractice() {
        guard phase == .review else { return }
        record(.completed); clearSession(beginCooldown: false)
    }
    func end(_ outcome: PracticeOutcome = .interrupted, at uptime: Double = ProcessInfo.processInfo.systemUptime) {
        guard phase != .idle else { return }
        let wasReview = phase == .review
        if phase == .active, let clock { remaining = clock.remaining(at: uptime) }
        record(phase == .offered ? .dismissed : phase == .review ? .unconfirmed : outcome)
        clearSession(beginCooldown: !wasReview)
    }
    private func record(_ outcome: PracticeOutcome) {
        guard let id = sessionID else { return }
        let event = PracticeEvent(id: id, date: sessionDate, source: sessionSource, response: sessionResponse, target: sessionDuration,
                                  elapsed: sessionDuration - remaining, outcome: outcome,
                                  change: outcome == .completed ? change : nil,
                                  urgeBefore: nil,
                                  urgeAfter: nil,
                                  trigger: outcome == .completed ? trigger : nil)
        if let index = events.firstIndex(where: { $0.id == id }) { events[index] = event }
        else { events.append(event) }
        if events.count > 5000 { events.removeFirst(events.count - 5000) }
        persist()
    }
    private func clearSession(beginCooldown: Bool = true) {
        if beginCooldown { lastOffer = ProcessInfo.processInfo.systemUptime }
        phase = .idle; clock = nil; sessionID = nil; overlayMinimized = false
        onDismiss?()
    }
    func refreshOverlay() { if phase != .idle { onPresent?() } }
    func minimizeOverlay() {
        guard phase == .active else { return }
        overlayMinimized = true; autoDockHandled = true
        onPresent?()
    }
    func present() {
        guard phase != .idle else { return }
        if overlayMinimized { autoDockHandled = true }
        overlayMinimized = false
        onInteraction?()
        onPresent?()
    }
    func resetPracticeData() {
        guard available, phase == .idle else { return }
        let alert = NSAlert(); alert.messageText = "Reset HRT statistics and history?"
        alert.informativeText = "This resets all practice counters and deletes HRT practice history. Your HRT plan, camera detection statistics and snapshots are kept."
        alert.addButton(withTitle: "Reset HRT statistics").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""
        guard let window = NSApp.mainWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.phase == .idle else { return }
            self.performReset()
        }
    }
    private func performReset() {
        guard available && phase == .idle else { return }
        var clean = document; clean.resetHistory()
        let url = folder.appendingPathComponent("practice.json")
        resetting = true
        disk.async { [weak self] in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(clean).write(to: url, options: .atomic)
                DispatchQueue.main.async {
                    self?.events = []; self?.historyExpanded = false; self?.resetting = false
                    self?.message = "HRT statistics and history reset."
                }
            } catch { DispatchQueue.main.async {
                self?.resetting = false
                self?.message = "Could not reset practice data: \(error.localizedDescription)"
            } }
        }
    }

}

func overlaySnapshotSize(image: CGSize, width: CGFloat) -> CGSize {
    let w = max(1, width)
    let ratio = image.width > 0 && image.height > 0 ? image.height / image.width : 0.75
    return CGSize(width: w, height: w * ratio)
}

func practiceOverlayFrame(visible: CGRect, size: CGSize, compact: Bool, position: String, screen: CGRect? = nil) -> CGRect {
    let center = compact ? visible : (screen ?? visible)
    let inset: CGFloat = compact ? 8 : 24
    let width = min(size.width, visible.width - 32), height = min(size.height, visible.height - 32)
    let x = position.contains("Left") ? visible.minX + inset : position.contains("Right") ? visible.maxX - width - inset : center.midX - width / 2
    let y = position.contains("Bottom") ? visible.minY + inset : position.contains("Top") ? visible.maxY - height - inset : center.midY - height / 2
    return CGRect(x: min(max(visible.minX + 8, x), visible.maxX - width - 8), y: min(max(visible.minY + 8, y), visible.maxY - height - 8), width: width, height: height)
}

struct PracticeOverlayView: View {
    @ObservedObject var training: PracticeController
    let accent: Color
    let width: CGFloat
    let image: NSImage?
    let banner: Bool
    let compact: Bool
    var body: some View {
        Group {
            if compact {
                HStack(spacing: 14) {
                    Button { training.present() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised.fill").foregroundStyle(accent)
                            Text("HRT").font(.headline)
                            Text(training.shortTime).font(.title3.bold()).monospacedDigit()
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Expand practice overlay")
                    Button { training.end() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Stop practice")
                }.padding(14)
            } else if banner && training.phase != .review {
                bannerContent
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Label(training.phase == .review ? "HRT timer finished" : "Hands away · HRT Practice", systemImage: "hand.raised.fill").font(.headline)
                        Spacer()
                        if training.phase == .active {
                            Button { training.minimizeOverlay() } label: { Image(systemName: "arrow.up.to.line.compact") }.buttonStyle(.plain).help("Dock the timer and remove dimming")
                        }
                    }
                    if training.phase != .review, let image {
                        let size = overlaySnapshotSize(image: image.size, width: width - 40)
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: size.width, height: size.height)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if training.phase != .review {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("YOUR RESPONSE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(training.sessionResponse.rawValue).font(.headline)
                            Text(training.sessionResponse.instruction).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if training.phase == .active {
                        Text(training.shortTime).font(.system(size: 44, weight: .medium, design: .rounded)).monospacedDigit()
                        ProgressView(value: training.progress).tint(accent).accessibilityLabel("Practice progress")
                        HStack {
                            Button("Dock timer") { training.minimizeOverlay() }.buttonStyle(.borderedProminent)
                            Button("Stop") { training.end() }
                        }
                        Text("Keep it gentle. Stop if uncomfortable.").font(.caption).foregroundStyle(.secondary)
                    } else if training.phase == .offered {
                        Text("Ready when you are · \(training.sessionDuration) seconds").font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Start practice") { training.startPractice() }.buttonStyle(.borderedProminent)
                            Button("Not now") { training.end() }
                        }
                        Text("Closes after 30 seconds if not started.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        checkInContent
                    }
                }.padding(20)
            }
        }.frame(maxWidth: .infinity).tint(accent)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 20 : banner ? 12 : 16))
            .overlay(RoundedRectangle(cornerRadius: compact ? 20 : banner ? 12 : 16).strokeBorder(accent.opacity(0.85), lineWidth: compact || banner ? 1.5 : 3))
    }
    private var checkInContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Did you practise the response?").foregroundStyle(.secondary)
            Picker("Urge compared with before", selection: $training.change) {
                ForEach(UrgeChange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Context (optional)", selection: $training.trigger) {
                ForEach(PracticeTrigger.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Button("I practised") { training.confirmPractice() }.buttonStyle(.borderedProminent)
                Button("Skip") { training.end() }
            }
            Text("Alerts can resume without this check-in. Closes after 2 minutes, or when a new practice is offered.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var bannerContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 18, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 30, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(training.sessionResponse.rawValue).font(.headline).lineLimit(1)
                    Text(training.phase == .offered ? "HRT practice · \(training.sessionDuration) s" : training.phase == .active ? "Keep your hands away" : "HRT timer finished")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if training.phase == .offered {
                    Button("Start") { training.startPractice() }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                        .help("Start the practice countdown")
                } else if training.phase == .active {
                    Text(training.shortTime).font(.title2.weight(.semibold)).monospacedDigit().fixedSize()
                    Button { training.minimizeOverlay() } label: { Image(systemName: "arrow.up.to.line.compact") }
                        .buttonStyle(.plain).help("Dock timer")
                } else {
                    Button("Done") { training.confirmPractice() }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button { training.end() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20, height: 26).contentShape(Rectangle())
                }.buttonStyle(.plain).help(training.phase == .offered ? "Dismiss without starting; invitations close after 30 seconds" : "Stop practice")
            }
            if training.phase == .active {
                ProgressView(value: training.progress).tint(accent).accessibilityLabel("Practice progress")
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

}

struct PracticeCard: View {
    @ObservedObject var training: PracticeController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "hands.sparkles").font(.title2.bold())
            if training.phase == .offered {
                instruction
                Text("The timer starts when you press Start practice.").foregroundStyle(.secondary)
                HStack {
                    Button("Start practice") { training.startPractice() }.buttonStyle(.borderedProminent)
                    Button("Not now") { training.end() }
                }
            } else if training.phase == .active {
                instruction
                Text(training.shortTime).font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity)
                ProgressView(value: training.progress).accessibilityLabel("Practice progress")
                Text("Breathe normally. The camera keeps monitoring, with alerts quiet during this practice. The timer does not assess your hands.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button(training.overlayMinimized ? "Expand overlay" : "Dock timer") { training.overlayMinimized ? training.present() : training.minimizeOverlay() }
                    Button("Stop practice") { training.end() }
                }
            } else if training.phase == .review {
                Text("The timer has finished. Did you practise the response?")
                Picker("Urge compared with before", selection: $training.change) {
                    ForEach(UrgeChange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Picker("What was happening? (optional)", selection: $training.trigger) {
                    ForEach(PracticeTrigger.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text("A strong urge is useful information. You do not need to make it disappear to record your practice.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("I practised") { training.confirmPractice() }.buttonStyle(.borderedProminent)
                    Button("Skip check-in") { training.end() }
                }
                Text("The overlay closes when the timer ends. Check in here within 2 minutes, or leave the practice unconfirmed.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Notice. Lower your hands. Practise your chosen response.")
                Text("Start when you notice an urge yourself, or rehearse while things are calm.").foregroundStyle(.secondary)
                HStack {
                    Button("I noticed an urge") { training.manual(.noticed) }.buttonStyle(.borderedProminent)
                    Button("Rehearse") { training.manual(.rehearsal) }
                }.disabled(!training.preferences.enabled || !training.available)
                if !training.preferences.enabled { Text("Enable HRT support above to begin.").font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var title: String {
        switch training.phase { case .idle: return "A moment for your hands"; case .offered: return "Ready to practise?"; case .active: return "Practise your response"; case .review: return "A brief check-in" }
    }
    var instruction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(training.sessionResponse.rawValue).font(.headline)
            Text(training.sessionResponse.instruction)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

}

struct PracticeChoice<Value: Hashable>: View {
    let title: String
    @Binding var value: Value
    let choices: [(Value, String)]
    var body: some View {
        Menu {
            ForEach(choices.indices, id: \.self) { index in
                Button { value = choices[index].0 } label: {
                    if value == choices[index].0 { Label(choices[index].1, systemImage: "checkmark") }
                    else { Text(choices[index].1) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text(choices.first(where: { $0.0 == value })?.1 ?? "Choose").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(width: 240, height: 30)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(title).accessibilityValue(choices.first(where: { $0.0 == value })?.1 ?? "Choose")
    }
}

struct PracticeView: View {
    @ObservedObject var training: PracticeController
    @ObservedObject var model: Model
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("HRT Practice").font(.largeTitle.bold())
                        Text("Build awareness and practise a different response.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("HRT support", isOn: $training.preferences.enabled).toggleStyle(.switch).fixedSize().disabled(!training.available)
                }
                if !training.message.isEmpty { Text(training.message).foregroundStyle(.orange).textSelection(.enabled) }
                PracticeCard(training: training).padding(20).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                plan
                PracticeStatistics(training: training)
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("HRT data").font(.headline)
                        Text("Reset all practice counters and history. Your plan, detection statistics and snapshots are kept.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(training.resetting ? "Resetting..." : "Reset HRT statistics...", role: .destructive) { training.resetPracticeData() }
                        .buttonStyle(.bordered).controlSize(.regular).fixedSize()
                        .disabled(training.phase != .idle || !training.available || training.events.isEmpty)
                }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                DisclosureGroup("Recent HRT history", isExpanded: $training.historyExpanded) {
                    if training.events.isEmpty { Text("Your HRT records will appear here.").foregroundStyle(.secondary).padding(.top, 12) }
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(training.events.suffix(30).reversed())) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(event.outcome.rawValue).font(.headline); Spacer(); Text(event.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                                Text("\(event.source.rawValue) · \(event.response.rawValue) · \(event.elapsed)/\(event.target) s").font(.callout)
                                if let change = event.change { Text("Urge: \(change.rawValue)\(event.urgeBefore.flatMap { first in event.urgeAfter.map { " (\(first) → \($0)/10)" } } ?? "") · \(event.trigger?.rawValue ?? "Not sure")").font(.caption).foregroundStyle(.secondary) }
                            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.padding(.top, 12)
                    Text("Latest 30 records shown; up to 5,000 kept locally. Timer completion is not proof of practice or reduced biting.").font(.caption).foregroundStyle(.secondary)
                }.padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                guidance
            }.padding(24).frame(maxWidth: 980).frame(maxWidth: .infinity)
        }
    }
    var plan: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your HRT plan").font(.headline)
                Spacer()
                Button("Overlay appearance") { model.controlPage = "Overlay"; model.tab = 0 }.buttonStyle(.bordered).controlSize(.regular)
            }
            Text("A detection offers a practice. Start the timer when you are ready.").font(.callout).foregroundStyle(.secondary)
            Divider()
            planRow("Competing response", detail: training.preferences.response.instruction) {
                PracticeChoice(title: "Competing response", value: $training.preferences.response,
                               choices: PracticeResponse.allCases.map { ($0, $0.rawValue) }).disabled(training.busy)
            }
            Divider()
            planRow("Practice length", detail: "The timer starts only after you press Start.") {
                PracticeChoice(title: "Practice length", value: $training.preferences.seconds,
                               choices: [(60, "1 minute"), (90, "90 seconds"), (120, "2 minutes")]).disabled(training.busy)
            }
            Divider()
            planRow("During the countdown", detail: "Docking removes dimming. You can expand the small timer again at any time.") {
                PracticeChoice(title: "During the countdown", value: $model.settings.hrtAutoDock,
                               choices: [(false, "Keep expanded"), (true, "Dock after 5 seconds")])
            }
            planRow("Docked timer position", detail: "Choose where the small timer appears on the selected displays.") {
                PracticeChoice(title: "Docked timer position", value: $model.settings.hrtDockPosition,
                               choices: ([Settings.followOverlayPosition] + Settings.overlayPositions).map { ($0, $0) })
            }
            Divider()
            planRow("Cooldown after practice", detail: "Off allows the next new detection to prompt immediately after the current session ends.") {
                PracticeChoice(title: "Cooldown after practice", value: $training.preferences.cooldown,
                               choices: [(0, "Off"), (60, "1 minute"), (120, "2 minutes"), (300, "5 minutes"), (600, "10 minutes")])
            }
            Divider()
            planRow("Check-in after timer", detail: "Optional popup. It never delays new detection alerts; your cooldown starts when the timer ends.") {
                PracticeChoice(title: "Check-in after timer", value: $model.settings.hrtCheckIn,
                               choices: [(true, "Show optional popup"), (false, "Off")])
            }
            Divider()
            planRow("Timer completion sound", detail: "Separate from the detection alert. Selecting a sound previews it.") {
                PracticeChoice(title: "Timer completion sound", value: $model.settings.hrtFinishSound,
                               choices: (["None"] + soundNames).map { ($0, $0) })
            }
            planRow("Completion volume", detail: "Volume for the end-of-practice sound only.") {
                HStack {
                    Slider(value: $model.settings.hrtFinishVolume, in: 0...1, step: 0.05)
                    Text("\(Int(model.settings.hrtFinishVolume * 100))%").monospacedDigit().frame(width: 40)
                }.frame(width: 240).disabled(model.settings.hrtFinishSound == "None")
            }
            Divider()
            Label(training.shortcutAvailable ? "I noticed an urge: Control + Option + H" : "I noticed an urge: available in the menu bar", systemImage: "keyboard").font(.callout)
            Text("No camera needed for manual practice. Lock, sleep and Quit stop an unfinished session.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 14)).disabled(training.resetting)
    }
    func planRow<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().pickerStyle(.menu).labelsHidden().controlSize(.regular)
                .frame(width: 260, alignment: .leading)
        }
    }
    var guidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("How to use this experiment", systemImage: "info.circle").font(.headline)
            Text("1. Choose a comfortable response and enable support. Rehearse it once while calm.\n2. Use it when you notice an urge or early hand movement, including away from your Mac.\n3. Notice what helps. There are no streaks to lose and no penalties for stopping.")
            Text("This is a self-help feature informed by HRT, not a tested treatment. It does not verify nail biting, hand position during practice, or clinical improvement. Use gentle contact, not force; stop if painful. A therapist familiar with HRT and body-focused repetitive behaviours can help tailor the response, especially if biting causes injury or distress.").font(.callout).foregroundStyle(.secondary)
            HStack { Link("HRT research", destination: URL(string: "https://pmc.ncbi.nlm.nih.gov/articles/PMC9672630/")!); Link("Understanding nail biting", destination: URL(string: "https://www.bfrb.org/nail-biting")!) }
        }.padding(20).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PracticeStatistics: View {
    @ObservedObject var training: PracticeController
    var interval: DateInterval? = nil
    var selected: [PracticeEvent] {
        let window = interval ?? DateInterval(start: Calendar.current.startOfDay(for: Date()), end: Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!)
        return training.events.filter { $0.date >= window.start && $0.date < window.end }
    }
    var body: some View {
        let records = selected
        let completed = records.filter { $0.outcome == .completed }
        VStack(alignment: .leading, spacing: 14) {
            Text(interval == nil ? "HRT Practice today" : "HRT Practice in selected range").font(.headline)
            HStack(alignment: .top, spacing: 32) {
                metric("Self-noticed urges", records.filter { $0.source == .noticed }.count)
                metric("Confirmed practices", completed.count)
                metric("Urge felt lower", completed.filter { $0.change == .less }.count)
                metric("Stopped early", records.filter { $0.outcome == .interrupted }.count)
            }
            Text("Self-noticed counts include stopped practices. Confirmed practice and urge changes are your reports, not camera measurements. These counts do not measure treatment effectiveness.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
    func metric(_ label: String, _ count: Int) -> some View { VStack(alignment: .leading, spacing: 5) { Text("\(count)").font(.title.bold()).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) } }
}

func testPractice() throws {
    let clock = PracticeClock(start: 100, duration: 60)
    precondition(clock.remaining(at: 100) == 60 && clock.remaining(at: 159.9) == 1)
    precondition(clock.remaining(at: 160) == 0 && clock.remaining(at: 5000) == 0)
    precondition(clock.remaining(at: 90) == 60)
    var document = PracticeDocument()
    document.preferences.seconds = -1; document.preferences.cooldown = -1; document.normalize()
    precondition(document.preferences.seconds == 60 && document.preferences.cooldown == PracticePreferences().cooldown)
    let decoded = try JSONDecoder().decode(PracticeDocument.self, from: JSONEncoder().encode(document))
    precondition(decoded.preferences == document.preferences && decoded.events.isEmpty)
    let event = PracticeEvent(id: UUID(), date: Date(), source: .noticed, response: .fists, target: 60, elapsed: 60, outcome: .completed, change: .less, urgeBefore: 8, urgeAfter: 3, trigger: .focus)
    document.events = [event]
    var resetCopy = document
    resetCopy.resetHistory()
    precondition(resetCopy.events.isEmpty && resetCopy.preferences == document.preferences && document.events.count == 1)
    let roundtrip = try JSONDecoder().decode(PracticeDocument.self, from: JSONEncoder().encode(document))
    precondition(roundtrip.events[0].urgeBefore == 8 && roundtrip.events[0].outcome == .completed)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NailGuard-HRT-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let training = PracticeController(folder: root)
    var presentations = 0, dismissals = 0
    training.onPresent = { presentations += 1 }; training.onDismiss = { dismissals += 1 }
    let t = ProcessInfo.processInfo.systemUptime
    precondition(!training.offerFromCamera(at: t) && training.phase == .idle)
    training.preferences.enabled = true
    training.preferences.cooldown = 120
    precondition(training.offerFromCamera(at: t) && training.cameraOfferPending && training.remaining == 60)
    precondition(!training.offerFromCamera(at: t + 1))
    training.tick(at: t + 21)
    precondition(presentations == 1 && dismissals == 0)
    precondition(training.phase == .offered && training.remaining == 60 && training.events.isEmpty)
    training.startPractice(at: t)
    precondition(training.phase == .active && !training.cameraOfferPending)
    training.startPractice(at: t + 10)
    training.minimizeOverlay()
    precondition(training.overlayMinimized)
    training.present()
    precondition(!training.overlayMinimized)
    training.tick(at: t + 30)
    precondition(training.remaining == 30)
    training.end(at: t + 30)
    precondition(presentations == 4 && dismissals == 1)
    precondition(training.events.last?.elapsed == 30 && training.events.last?.outcome == .interrupted)
    precondition(!training.offerFromCamera(at: ProcessInfo.processInfo.systemUptime + 119))
    precondition(training.offerFromCamera(at: ProcessInfo.processInfo.systemUptime + 121))
    training.end()
    training.manual(.noticed, at: t)
    training.manual(.noticed, at: t + 10)
    training.startPractice(at: t)
    training.tick(at: t + 30)
    precondition(training.phase == .active && training.remaining == 30)
    training.tick(at: t + 60)
    precondition(training.phase == .review && training.events.last?.outcome == .unconfirmed)
    let count = training.events.count
    training.change = .less; training.trigger = .focus
    training.confirmPractice()
    precondition(training.events.count == count && training.events.last?.outcome == .completed)
    precondition(training.events.last?.change == .less && training.events.last?.source == .noticed)
    training.confirmPractice()
    precondition(training.events.count == count)
    training.autoDock = true
    training.manual(.rehearsal, at: t)
    training.startPractice(at: t)
    training.tick(at: t + 4); precondition(!training.overlayMinimized)
    training.tick(at: t + 5); precondition(training.overlayMinimized)
    training.present(); training.tick(at: t + 6)
    precondition(!training.overlayMinimized && training.remaining == 54)
    training.tick(at: t + 60); training.tick(at: t + 181)
    precondition(training.phase == .idle && training.events.last?.outcome == .unconfirmed)
    training.manual(.noticed)
    training.startPractice(at: ProcessInfo.processInfo.systemUptime - 10)
    training.preferences.enabled = false
    precondition(training.phase == .idle && training.events.last?.outcome == .interrupted && training.events.last!.elapsed >= 10)
    training.preferences.enabled = true
    training.preferences.cooldown = 0
    precondition(training.offerFromCamera())
    let waiting = ProcessInfo.processInfo.systemUptime
    training.tick(at: waiting + 31)
    precondition(training.phase == .idle && training.events.last?.outcome == .dismissed && training.events.last?.elapsed == 0)
    for source in [PracticeSource.noticed, .rehearsal] {
        let offeredAt = ProcessInfo.processInfo.systemUptime
        training.manual(source, at: offeredAt)
        precondition(!training.cameraOfferPending)
        training.tick(at: offeredAt + 29)
        precondition(training.phase == .offered)
        training.tick(at: offeredAt + 30)
        precondition(training.phase == .idle && training.events.last?.source == source && training.events.last?.outcome == .dismissed)
    }
    precondition(training.offerFromCamera())
    training.end()
    training.preferences.enabled = false
    document.preferences.cooldown = 0; document.normalize()
    precondition(document.preferences.cooldown == 0)
    let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
    for compact in [true, false] {
        for position in ["Top Left", "Top", "Top Right", "Center", "Bottom Right", "Bottom"] {
            let frame = practiceOverlayFrame(visible: screen, size: CGSize(width: 420, height: 560), compact: compact, position: position)
            precondition(screen.contains(frame))
            if compact && position == "Top" { precondition(frame.midX == screen.midX && frame.maxY == screen.maxY - 8) }
            if compact && position == "Bottom Right" { precondition(frame.maxX == screen.maxX - 8 && frame.minY == screen.minY + 8) }
        }
    }
    let physical = CGRect(x: -1440, y: -200, width: 1440, height: 1000)
    let centered = practiceOverlayFrame(visible: screen, size: CGSize(width: 420, height: 360), compact: false, position: "Center", screen: physical)
    precondition(centered.midX == physical.midX && centered.midY == physical.midY)
    training.flush()
    let restored = PracticeController(folder: root)
    precondition(restored.events.count == training.events.count && !restored.preferences.enabled && restored.phase == .idle)
    let url = root.appendingPathComponent("practice.json")
    let corrupt = Data("unreadable test file".utf8); try corrupt.write(to: url)
    let protected = PracticeController(folder: root)
    precondition(!protected.available && !protected.message.isEmpty)
    protected.preferences.enabled = true; protected.manual(.noticed); protected.flush()
    let preserved = try Data(contentsOf: url)
    precondition(!protected.busy && preserved == corrupt)
    document.events = Array(repeating: event, count: 5001); document.normalize()
    precondition(document.events.count == 5000)
    let review = PracticeController(folder: root.appendingPathComponent("review-test"))
    review.preferences.enabled = true; review.preferences.cooldown = 120
    var finishes = 0
    review.onFinish = { finishes += 1 }
    review.manual(.rehearsal, at: 100); review.startPractice(at: 100); review.tick(at: 160)
    precondition(review.phase == .review && !review.busy && finishes == 1)
    review.tick(at: 161); precondition(finishes == 1)
    precondition(!review.offerFromCamera(at: 279))
    precondition(review.offerFromCamera(at: 280))
    precondition(review.events.first?.outcome == .unconfirmed && review.events.count == 1)
    review.end()
    review.checkInEnabled = false; review.preferences.cooldown = 0
    review.manual(.rehearsal, at: 300); review.startPractice(at: 300); review.tick(at: 360)
    precondition(review.phase == .idle && !review.busy && finishes == 2)
    precondition(review.offerFromCamera(at: 360))
    review.end(); review.checkInEnabled = true
    review.manual(.rehearsal, at: 400); review.startPractice(at: 400); review.tick(at: 460)
    review.checkInEnabled = false
    precondition(review.phase == .idle && review.events.last?.outcome == .unconfirmed)
    review.flush()
    for size in [CGSize(width: 640, height: 480), CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080)] {
        let fitted = overlaySnapshotSize(image: size, width: 384)
        precondition(fitted.width == 384 && abs(fitted.height / fitted.width - size.height / size.width) < 0.00001)
    }
    print("PASS: HRT nonblocking/disabled check-in, one completion callback, snapshot ratios, button start, idle countdown, disabled cooldown, persistent countdown, dock/expand, overlay placement, cooldown, duplicate suppression, self-report confirmation, interruption, isolated persistence, corrupt-file protection and retention")
}
