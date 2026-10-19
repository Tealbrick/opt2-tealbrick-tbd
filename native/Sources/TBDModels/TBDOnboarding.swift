import Foundation

/// First-launch onboarding (WP-ONB, C285 STREAMLINE, C286). Pure state: the persisted record, the step rules and the
/// summary lines. The app supplies the dependency checks (`TBDOnboardingChecks`) and draws the screens.
///
/// Rules (coordination/leads/tbd/ONBOARDING-SPEC.md):
/// - One record in UserDefaults, key `tbd.onboarding`, written on every Forward/Back.
/// - A step is done by a CHECK of the real dependency, or by an explicit "No" / "Not now". Resume re-checks.
/// - Back keeps every choice. A link from the app opens the flow at that step in edit mode; Forward then goes to the
///   summary.
/// - The Screen recording relaunch stores the step and the old PID; the next start resumes at Permissions.
public enum TBDOnboardingStep: String, Codable, CaseIterable, Comparable, Sendable {
    case welcome, portal, agent, permissions, models, summary

    public var index: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.index < b.index }
    var next: Self? { index + 1 < Self.allCases.count ? Self.allCases[index + 1] : nil }
    var previous: Self? { index > 0 ? Self.allCases[index - 1] : nil }
}

/// The person's answer to a step's yes/no question. nil = not answered yet.
public enum TBDOnboardingAnswer: String, Codable, Sendable { case yes, no }

/// How TBD's own agent (step 2) or the Companion model (step 4) runs.
public enum TBDOnboardingRuntime: String, Codable, Sendable { case subscription, apiKey, local }

/// A macOS permission row of step 3.
public enum TBDOnboardingPermission: String, Codable, CaseIterable, Sendable {
    case screenRecording, microphone, accessibility, notifications
}

public struct TBDOnboardingChoices: Codable, Equatable, Sendable {
    public var portal: TBDOnboardingAnswer?
    public var agent: TBDOnboardingAnswer?
    public var agentRuntime: TBDOnboardingRuntime?
    public var companion: TBDOnboardingAnswer?
    public var companionRuntime: TBDOnboardingRuntime?
    /// "No" to the speech model in step 4.
    public var speech: TBDOnboardingAnswer?
    /// Rows the person answered "Not now".
    public var permissionsNotNow: Set<TBDOnboardingPermission>
    public init(portal: TBDOnboardingAnswer? = nil, agent: TBDOnboardingAnswer? = nil, agentRuntime: TBDOnboardingRuntime? = nil,
                companion: TBDOnboardingAnswer? = nil, companionRuntime: TBDOnboardingRuntime? = nil,
                speech: TBDOnboardingAnswer? = nil, permissionsNotNow: Set<TBDOnboardingPermission> = []) {
        self.portal = portal; self.agent = agent; self.agentRuntime = agentRuntime; self.companion = companion
        self.companionRuntime = companionRuntime; self.speech = speech; self.permissionsNotNow = permissionsNotNow
    }
}

/// Where the flow was when TBD quit itself for the Screen recording grant.
public struct TBDOnboardingRelaunch: Codable, Equatable, Sendable {
    public var requestedAt: Date
    public var pid: Int32
    public init(requestedAt: Date, pid: Int32) { self.requestedAt = requestedAt; self.pid = pid }
}

public struct TBDOnboardingRecord: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var step: TBDOnboardingStep
    public var completed: Bool
    /// true when the flow was opened from a link in the app (or Settings): Forward goes to the summary.
    public var editing: Bool
    public var choices: TBDOnboardingChoices
    public var relaunch: TBDOnboardingRelaunch?
    public var updatedAt: Date
    public init(step: TBDOnboardingStep = .welcome, completed: Bool = false, editing: Bool = false,
                choices: TBDOnboardingChoices = TBDOnboardingChoices(), relaunch: TBDOnboardingRelaunch? = nil, updatedAt: Date) {
        self.version = Self.currentVersion; self.step = step; self.completed = completed; self.editing = editing
        self.choices = choices; self.relaunch = relaunch; self.updatedAt = updatedAt
    }
}

/// The real dependencies, read by the app at each check (every 2 s on the Permissions step, and on resume).
public struct TBDOnboardingChecks: Equatable, Sendable {
    public var signedIn: Bool
    public var workspaceName: String?
    public var agentModelReady: Bool
    public var agentModelName: String?
    public var agentPaired: Bool
    public var granted: Set<TBDOnboardingPermission>
    public var companionModelReady: Bool
    public var companionModelName: String?
    public var speechModelOnDisk: Bool
    /// Download progress 0...1 while a model downloads in the background (C286 F3: the person may go on). nil = none running.
    public var companionDownload: Double?
    public var speechDownload: Double?
    /// Paid apps (C282) that gate a TBD function, with whether the workspace has them. Empty when unknown.
    public var paidApps: [(name: String, function: String, active: Bool)]
    public init(signedIn: Bool = false, workspaceName: String? = nil, agentModelReady: Bool = false, agentModelName: String? = nil,
                agentPaired: Bool = false, granted: Set<TBDOnboardingPermission> = [], companionModelReady: Bool = false,
                companionModelName: String? = nil, speechModelOnDisk: Bool = false,
                companionDownload: Double? = nil, speechDownload: Double? = nil,
                paidApps: [(name: String, function: String, active: Bool)] = []) {
        self.signedIn = signedIn; self.workspaceName = workspaceName; self.agentModelReady = agentModelReady
        self.agentModelName = agentModelName; self.agentPaired = agentPaired; self.granted = granted
        self.companionModelReady = companionModelReady; self.companionModelName = companionModelName
        self.speechModelOnDisk = speechModelOnDisk
        self.companionDownload = companionDownload; self.speechDownload = speechDownload; self.paidApps = paidApps
    }
    public static func == (a: Self, b: Self) -> Bool {
        a.signedIn == b.signedIn && a.workspaceName == b.workspaceName && a.agentModelReady == b.agentModelReady
            && a.agentModelName == b.agentModelName && a.agentPaired == b.agentPaired && a.granted == b.granted
            && a.companionModelReady == b.companionModelReady && a.companionModelName == b.companionModelName
            && a.speechModelOnDisk == b.speechModelOnDisk
            && a.companionDownload == b.companionDownload && a.speechDownload == b.speechDownload
            && a.paidApps.map { "\($0.name)|\($0.function)|\($0.active)" } == b.paidApps.map { "\($0.name)|\($0.function)|\($0.active)" }
    }
}

/// What the app shows at launch.
public enum TBDOnboardingLaunch: Equatable, Sendable {
    /// The flow, at this step (edit = opened for one change).
    case flow(TBDOnboardingStep, editing: Bool)
    /// The app.
    case app
}

/// Loads and saves the record (UserDefaults, key `tbd.onboarding`, JSON).
public struct TBDOnboardingStore: @unchecked Sendable {
    public static let key = "tbd.onboarding"
    /// The setup screen this flow replaces (dev.1 to dev.8) wrote this flag.
    public static let legacyDoneKey = "didOnboard"
    let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TBDOnboardingRecord? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder.onboarding.decode(TBDOnboardingRecord.self, from: data)
    }

    public func save(_ record: TBDOnboardingRecord) {
        guard let data = try? JSONEncoder.onboarding.encode(record) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

private extension JSONDecoder {
    static var onboarding: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
private extension JSONEncoder {
    static var onboarding: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e }
}

/// The flow's rules. Every mutation saves the record.
public struct TBDOnboardingMachine: Sendable {
    public private(set) var record: TBDOnboardingRecord
    let store: TBDOnboardingStore
    let now: @Sendable () -> Date

    /// Loads the record, or starts one. An install that finished the old setup screen (didOnboard) and has no record
    /// opens once at the summary in edit mode: it shows what is still missing, and "Open TBD" closes it.
    public init(store: TBDOnboardingStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.now = now
        if let saved = store.load() {
            record = saved
        } else if store.defaults.bool(forKey: TBDOnboardingStore.legacyDoneKey) {
            record = TBDOnboardingRecord(step: .summary, completed: false, editing: true, updatedAt: now())
            store.save(record)
        } else {
            record = TBDOnboardingRecord(updatedAt: now())
        }
    }

    /// At launch: an unfinished flow opens at its saved step (after the self-relaunch: Permissions). The relaunch
    /// marker is cleared here; the step then re-checks the grant.
    public mutating func launch() -> TBDOnboardingLaunch {
        if record.relaunch != nil {
            record.relaunch = nil
            if !record.completed { record.step = .permissions }
            persist()
        }
        return record.completed ? .app : .flow(record.step, editing: record.editing)
    }

    /// True when the step may be left with Forward: its dependency checks OK, or the person said No / Not now.
    public func isDone(_ step: TBDOnboardingStep, _ c: TBDOnboardingChecks) -> Bool {
        let choices = record.choices
        switch step {
        case .welcome, .summary:
            return true
        case .portal:
            return choices.portal == .no || (c.signedIn && c.workspaceName != nil)
        case .agent:
            if choices.agent == .no { return true }
            // Paired only when the person also uses the workspace (spec step 2).
            return c.agentModelReady && (choices.portal != .yes || !c.signedIn || c.agentPaired)
        case .permissions:
            return TBDOnboardingPermission.allCases.allSatisfy { c.granted.contains($0) || choices.permissionsNotNow.contains($0) }
        case .models:
            // A running download counts: it continues in the background and the summary shows it (C286 F3).
            let companion = choices.companion == .no || c.companionModelReady || c.companionDownload != nil
            let speech = choices.speech == .no || c.speechModelOnDisk || c.speechDownload != nil
            return companion && speech
        }
    }

    public mutating func update(_ change: (inout TBDOnboardingChoices) -> Void) {
        change(&record.choices)
        persist()
    }

    /// Forward: needs `isDone`. In edit mode a done step goes straight to the summary.
    @discardableResult
    public mutating func forward(_ c: TBDOnboardingChecks) -> Bool {
        guard isDone(record.step, c), let next = record.step.next else { return false }
        record.step = record.editing ? .summary : next
        persist()
        return true
    }

    /// Back: one step back; every choice stays.
    public mutating func back() {
        guard let previous = record.step.previous else { return }
        record.step = previous
        persist()
    }

    /// A missing-dependency link in the app (or "Change" on the summary) opens the flow at this step in edit mode.
    public mutating func edit(_ step: TBDOnboardingStep) {
        record.step = step
        record.editing = true
        record.completed = false
        persist()
    }

    /// "Open TBD" on the summary.
    public mutating func finish() {
        record.step = .summary
        record.completed = true
        record.editing = false
        persist()
    }

    /// Before TBD quits itself for the Screen recording grant.
    public mutating func markRelaunch(pid: Int32) {
        record.step = .permissions
        record.relaunch = TBDOnboardingRelaunch(requestedAt: now(), pid: pid)
        persist()
    }

    private mutating func persist() {
        record.updatedAt = now()
        store.save(record)
    }
}

// MARK: - Summary lines (spec "Summary lines")

/// One plain line of the summary: what works now, or what is missing and the one thing to do.
public struct TBDOnboardingLine: Equatable, Sendable {
    public enum Fix: Equatable, Sendable {
        /// Opens the flow at this step.
        case step(TBDOnboardingStep)
        /// Opens the paid app's page in the Portal.
        case portal(app: String)
    }
    public let area: String
    public let on: Bool
    public let text: String
    public let action: String
    public let fix: Fix
}

public enum TBDOnboardingSummary {
    /// One line per area, in the spec's order. Dictation lists each missing piece in its own line.
    public static func lines(_ c: TBDOnboardingChecks) -> [TBDOnboardingLine] {
        var out: [TBDOnboardingLine] = []
        func add(_ area: String, _ on: Bool, _ text: String, _ action: String, _ fix: TBDOnboardingLine.Fix) {
            out.append(TBDOnboardingLine(area: area, on: on, text: text, action: action, fix: fix))
        }
        if c.signedIn, let ws = c.workspaceName {
            add("Workspace", true, "Signed in to \(ws). Your workspace agents and teams are in Chat.", "Change", .step(.portal))
        } else {
            add("Workspace", false, "Not signed in. Chat shows only TBD's own agent.", "Sign in", .step(.portal))
        }
        if c.agentModelReady {
            let model = c.agentModelName.map { " with \($0)" } ?? ""
            add("TBD's agent", true, "TBD's agent runs on this Mac\(model).", "Change", .step(.agent))
        } else {
            add("TBD's agent", false, "TBD's agent is off. Chat has only your workspace agents.", "Set up", .step(.agent))
        }
        if c.granted.contains(.screenRecording) {
            add("Screen activity", true, "TBD records your screen and makes your timeline.", "Change", .step(.permissions))
        } else {
            add("Screen activity", false, "TBD records nothing. Timeline, Daily and Weekly stay empty.", "Allow", .step(.permissions))
        }
        if !c.companionModelReady, let p = c.companionDownload {
            add("Daily and Weekly", true, "The model for Daily and Weekly is downloading (\(percent(p))). Daily starts when it is done.", "Change", .step(.models))
        } else if c.companionModelReady {
            let model = c.companionModelName.map { " use \($0)" } ?? " have a model"
            add("Daily and Weekly", true, "Daily and Weekly\(model).", "Change", .step(.models))
        } else {
            add("Daily and Weekly", false, "No model for Daily and Weekly. Your timeline is recorded, not summarised.", "Choose a model", .step(.models))
        }
        let speechDownloading = !c.speechModelOnDisk && c.speechDownload != nil
        let dictationGaps: [(String, String, TBDOnboardingStep)] = [
            c.speechModelOnDisk || speechDownloading ? nil : ("Download the speech model to dictate.", "Download", .models),
            c.granted.contains(.microphone) ? nil : ("Allow the microphone to dictate and record meetings.", "Allow", .permissions),
            c.granted.contains(.accessibility) ? nil : ("Allow Accessibility to type dictation into other apps.", "Allow", .permissions),
        ].compactMap { $0 }
        if speechDownloading, let p = c.speechDownload {
            add("Dictation and meetings", true, "The speech model is downloading (\(percent(p))). Dictation works when it is done.", "Change", .step(.models))
        }
        if dictationGaps.isEmpty && !speechDownloading {
            add("Dictation and meetings", true, "Dictation and meeting notes work. The speech model is on this Mac.", "Change", .step(.models))
        } else {
            for gap in dictationGaps { add("Dictation", false, gap.0, gap.1, .step(gap.2)) }
        }
        if c.granted.contains(.notifications) {
            add("Notifications", true, "TBD tells you when Daily is ready and when an agent needs you.", "Change", .step(.permissions))
        } else {
            add("Notifications", false, "TBD cannot tell you when Daily is ready or an agent needs you.", "Allow", .step(.permissions))
        }
        if c.signedIn {
            for app in c.paidApps {
                if app.active {
                    add(app.name, true, "\(app.function) works.", "Change", .portal(app: app.name))
                } else {
                    add(app.name, false, "\(app.name) is not in your workspace plan.", "Open in Portal", .portal(app: app.name))
                }
            }
        }
        return out
    }

    static func percent(_ p: Double) -> String { "\(Int((min(max(p, 0), 1) * 100).rounded()))%" }

    /// "Everything is ready." or "TBD works. <n> things are off." (one thing: "1 thing is off").
    public static func headline(_ lines: [TBDOnboardingLine]) -> String {
        let off = lines.filter { !$0.on }.count
        switch off {
        case 0: return "Everything is ready."
        case 1: return "TBD works. 1 thing is off."
        default: return "TBD works. \(off) things are off."
        }
    }
}

// MARK: - Subscription per harness (C286 F1)

/// The agent harnesses TBD can run. Only `claudeAgentSDK` (TBD's agent) and the CLI-based Companion providers exist today;
/// Codex, Eve and LangChain are shown as "coming later" (C286 F2, WP-HARNESS).
public enum TBDHarness: String, Codable, CaseIterable, Sendable {
    case claudeAgentSDK, claudeCodeCLI, codexCLI, eve, langChain
}

/// One flag per harness: may TBD offer "Subscription" (the person's own subscription login) for it? C287 (from Anthropic's
/// terms): an app built on the Agent SDK may NOT offer Claude.ai login, so TBD's own agent (`claudeAgentSDK`) runs only
/// on the person's API key or a local model, and the choice is hidden there. "Subscription" appears only for the
/// person's own installed, unmodified CLI: they sign in to that CLI themselves; TBD never reads, stores or proxies
/// tokens and never hides the CLI's login methods. Codex CLI keeps the Companion's existing ChatGPT route (A20).
/// Never name a TBD feature "Claude Code" (C287 (3)); "Use your Claude Code CLI" as a description is fine.
public enum TBDSubscriptionPolicy {
    public static let allowed: [TBDHarness: Bool] = [
        .claudeAgentSDK: false,
        .claudeCodeCLI: true,
        .codexCLI: true,
        .eve: false,
        .langChain: false,
    ]
    public static func isAllowed(_ harness: TBDHarness) -> Bool { allowed[harness] ?? false }
}
