import Foundation

/// Flow (WP4/WP5, DESIGN-FLOW.md 2.2-2.4): the local task list, reminders, focus timer, settings and the plan-vs-actual
/// card labels. Pure value types; `TBDFlowStore` persists them as one JSON file. Rules come from the Tasklist service
/// (`server.py`) that v1 Flow used; the field limits are the same.

// MARK: - Shared helpers

/// Dates in `flow.json` and in the reminder dedup keys: ISO 8601, UTC, milliseconds (`2026-10-05T07:00:00.000Z`).
/// Reading is tolerant: with or without a fraction, any offset, and Python's microseconds.
public enum TBDFlowISO {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    public static func string(_ date: Date) -> String { withFraction.string(from: date) }

    public static func date(_ value: String) -> Date? {
        if let d = withFraction.date(from: value) ?? plain.date(from: value) { return d }
        // Python writes microseconds (`.123456`): cut the fraction to milliseconds and retry.
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let digits = value[value.index(after: dot)...].prefix { $0.isNumber }
        let rest = value[value.index(dot, offsetBy: 1 + digits.count)...]
        let trimmed = String(value[..<dot]) + "." + String((digits + "000").prefix(3)) + rest
        return withFraction.date(from: trimmed)
    }
}

/// `yyyy-MM-dd` day keys, built from calendar components (no locale or formatter state).
public enum TBDFlowDay {
    public static func string(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// (year, month, day) when `value` is exactly `yyyy-MM-dd` and a real calendar date.
    public static func components(_ value: String) -> (year: Int, month: Int, day: Int)? {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              value.allSatisfy({ $0 == "-" || ("0"..."9").contains($0) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), y >= 1 else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        guard let date = gregorian.date(from: DateComponents(year: y, month: m, day: d)),
              gregorian.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d)
        else { return nil }
        return (y, m, d)
    }

    public static func isValid(_ value: String) -> Bool { components(value) != nil }
}

/// What a Flow operation refuses, with the text the UI shows.
public enum TBDFlowError: Error, Equatable, LocalizedError, Sendable {
    /// A task or draft broke a limit (`server.py` `task()`): the message names the rule.
    case invalid(String)
    case notFound(String)
    /// Same text as v1 (`CompanionPlanner.startFocus`).
    case timeboxEnded
    case timerBusy
    case noTimer
    case invalidTimerTransition
    case invalidSnooze
    case idempotencyKeyRequired
    /// 409 in the Tasklist API: the key was used for another schedule.
    case idempotencyConflict
    /// The file could not be written.
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .notFound(let what): return "\(what) not found"
        case .timeboxEnded: return "This timebox has ended. Replan it before starting focus."
        case .timerBusy: return "Stop the current timer before starting another"
        case .noTimer: return "No timer"
        case .invalidTimerTransition: return "Invalid timer transition"
        case .invalidSnooze: return "Snooze minutes must be 1–1440"
        case .idempotencyKeyRequired: return "idempotency_key required for commit"
        case .idempotencyConflict: return "Idempotency key already used for another schedule"
        case .storage(let m): return m
        }
    }
}

// MARK: - Tasks

public enum TBDFlowTaskStatus: String, Codable, CaseIterable, Sendable { case todo, doing, done, cancelled }

/// Where a task came from. `taskBoard` entries link an issue (F4); the timebox stays local.
public enum TBDFlowTaskSource: String, Codable, Sendable { case local, taskBoard }

public struct TBDFlowSubtask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var done: Bool
    public init(id: String, title: String, done: Bool = false) { self.id = id; self.title = title; self.done = done }
}

public struct TBDFlowTask: Codable, Equatable, Identifiable, Sendable {
    public static let maxTitle = 500
    public static let maxNotes = 100_000
    public static let maxSubtasks = 200

    public var id: String
    /// 1...500 characters.
    public var title: String
    /// 0...100 000 characters.
    public var notes: String
    /// 0...200 entries.
    public var subtasks: [TBDFlowSubtask]
    public var status: TBDFlowTaskStatus
    /// `yyyy-MM-dd`.
    public var day: String
    /// The timebox. `endAt` without `startAt` is allowed (a due time).
    public var startAt: Date?
    public var endAt: Date?
    public var source: TBDFlowTaskSource
    public var taskBoardID: String?
    public var taskBoardProject: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(id: String, title: String, notes: String = "", subtasks: [TBDFlowSubtask] = [], status: TBDFlowTaskStatus = .todo,
                day: String, startAt: Date? = nil, endAt: Date? = nil, source: TBDFlowTaskSource = .local,
                taskBoardID: String? = nil, taskBoardProject: String? = nil, createdAt: Date, updatedAt: Date? = nil,
                completedAt: Date? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.subtasks = subtasks; self.status = status; self.day = day
        self.startAt = startAt; self.endAt = endAt; self.source = source; self.taskBoardID = taskBoardID
        self.taskBoardProject = taskBoardProject; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }

    /// Length of the timebox in whole minutes; 0 when it has no start or no end (unknown, as in Tasklist).
    public var durationMinutes: Int {
        guard let startAt, let endAt, endAt > startAt else { return 0 }
        return Int(endAt.timeIntervalSince(startAt) / 60)
    }

    /// `server.py` `task()` limits. Throws `TBDFlowError.invalid` with the rule that failed.
    public func validate() throws {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > Self.maxTitle {
            throw TBDFlowError.invalid("Title required (max 500 characters)")
        }
        if notes.count > Self.maxNotes { throw TBDFlowError.invalid("Notes too long") }
        if subtasks.count > Self.maxSubtasks { throw TBDFlowError.invalid("Invalid subtasks") }
        for s in subtasks where s.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TBDFlowError.invalid("Subtask title required")
        }
        if !TBDFlowDay.isValid(day) { throw TBDFlowError.invalid("Day must be yyyy-MM-dd") }
        if let startAt, let endAt, endAt < startAt { throw TBDFlowError.invalid("End must follow start") }
    }
}

// MARK: - Reminders

public enum TBDFlowReminderKind: String, Codable, Sendable { case start, timeboxEnded }

/// A "Start: X" or "Timebox ended: X" alert. Created by `TBDFlowStore.tick`, once per `dedupKey`.
public struct TBDFlowReminder: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: TBDFlowReminderKind
    public var taskID: String
    public var title: String
    public var createdAt: Date
    public var acknowledgedAt: Date?
    public var snoozedUntil: Date?
    public var lastShownAt: Date?
    /// `<kind>:<taskID>:<startAt or endAt ISO>`: a changed time makes a new reminder, the same time never repeats.
    public var dedupKey: String

    public init(id: String, kind: TBDFlowReminderKind, taskID: String, title: String, createdAt: Date, dedupKey: String,
                acknowledgedAt: Date? = nil, snoozedUntil: Date? = nil, lastShownAt: Date? = nil) {
        self.id = id; self.kind = kind; self.taskID = taskID; self.title = title; self.createdAt = createdAt
        self.dedupKey = dedupKey; self.acknowledgedAt = acknowledgedAt; self.snoozedUntil = snoozedUntil
        self.lastShownAt = lastShownAt
    }

    public static func dedupKey(kind: TBDFlowReminderKind, taskID: String, at: Date) -> String {
        "\(kind.rawValue):\(taskID):\(TBDFlowISO.string(at))"
    }

    /// Unacknowledged and not snoozed at `now`.
    public func isPending(at now: Date) -> Bool {
        guard acknowledgedAt == nil else { return false }
        if let snoozedUntil, snoozedUntil > now { return false }
        return true
    }
}

// MARK: - Focus timer

public enum TBDFlowFocusMode: String, Codable, Sendable { case focus, `break` }
public enum TBDFlowFocusStatus: String, Codable, Sendable { case running, paused, stopped, finished }

public struct TBDFlowFocus: Codable, Equatable, Sendable {
    public var id: String
    public var taskID: String?
    public var mode: TBDFlowFocusMode
    public var status: TBDFlowFocusStatus
    public var startedAt: Date
    public var durationSeconds: Int
    /// While running. nil when paused, stopped by a pause, or finished before it was set.
    public var endsAt: Date?
    /// While paused.
    public var remainingSeconds: Double?
    public var finishedAt: Date?

    public init(id: String, taskID: String? = nil, mode: TBDFlowFocusMode, status: TBDFlowFocusStatus, startedAt: Date,
                durationSeconds: Int, endsAt: Date? = nil, remainingSeconds: Double? = nil, finishedAt: Date? = nil) {
        self.id = id; self.taskID = taskID; self.mode = mode; self.status = status; self.startedAt = startedAt
        self.durationSeconds = durationSeconds; self.endsAt = endsAt; self.remainingSeconds = remainingSeconds
        self.finishedAt = finishedAt
    }

    /// Whole seconds left at `now` (rounded up, as the v1 clock showed them): paused uses the stored value.
    public func remaining(at now: Date) -> Int {
        switch status {
        case .running: return max(0, Int((endsAt?.timeIntervalSince(now) ?? 0).rounded(.up)))
        case .paused: return max(0, Int((remainingSeconds ?? 0).rounded(.up)))
        case .stopped, .finished: return 0
        }
    }

    /// A timer the person can still pause, resume or stop.
    public var isActive: Bool { status == .running || status == .paused }
}

// MARK: - Settings

public struct TBDFlowSettings: Codable, Equatable, Sendable {
    /// How often a pending reminder shows again until it is acknowledged or snoozed (15...3600).
    public var repeatSeconds: Int
    /// 1...240.
    public var focusMinutes: Int
    /// 1...240.
    public var breakMinutes: Int
    public var sound: Bool
    public var overlay: Bool

    public init(repeatSeconds: Int = 60, focusMinutes: Int = 25, breakMinutes: Int = 5, sound: Bool = true, overlay: Bool = true) {
        self.repeatSeconds = repeatSeconds; self.focusMinutes = focusMinutes; self.breakMinutes = breakMinutes
        self.sound = sound; self.overlay = overlay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TBDFlowSettings()
        repeatSeconds = (try? c.decodeIfPresent(Int.self, forKey: .repeatSeconds)) ?? d.repeatSeconds
        focusMinutes = (try? c.decodeIfPresent(Int.self, forKey: .focusMinutes)) ?? d.focusMinutes
        breakMinutes = (try? c.decodeIfPresent(Int.self, forKey: .breakMinutes)) ?? d.breakMinutes
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? d.sound
        overlay = (try? c.decodeIfPresent(Bool.self, forKey: .overlay)) ?? d.overlay
    }

    /// `server.py` settings limits.
    public func validate() throws {
        if !(1...240).contains(focusMinutes) || !(1...240).contains(breakMinutes) {
            throw TBDFlowError.invalid("Duration must be 1–240 minutes")
        }
        if !(15...3600).contains(repeatSeconds) { throw TBDFlowError.invalid("Repeat interval must be 15–3600 seconds") }
    }
}

// MARK: - Plan vs actual labels

/// The label of one Companion timeline card.
public enum TBDFlowLabel: String, Codable, Sendable { case onPlan, offPlan, rest }

/// Who set a label. A person's choice is never overwritten by the model or the rules.
public enum TBDFlowLabelAuthor: String, Codable, Sendable {
    case person, model, rule

    /// person 3 > model 2 > rule 1.
    public var precedence: Int {
        switch self {
        case .person: return 3
        case .model: return 2
        case .rule: return 1
        }
    }
}

public struct TBDFlowCardLabel: Codable, Equatable, Sendable {
    public var cardID: String
    public var label: TBDFlowLabel
    /// Set for `.onPlan`.
    public var taskID: String?
    public var by: TBDFlowLabelAuthor
    public var at: Date
    public init(cardID: String, label: TBDFlowLabel, taskID: String? = nil, by: TBDFlowLabelAuthor, at: Date) {
        self.cardID = cardID; self.label = label; self.taskID = taskID; self.by = by; self.at = at
    }
}

// MARK: - Plan imports

/// A committed plan (`commit` with an idempotency key): the hash of the source and the tasks it made.
public struct TBDFlowImportRecord: Codable, Equatable, Sendable {
    public var sha256: String
    public var taskIDs: [String]
    public var at: Date
    public init(sha256: String, taskIDs: [String], at: Date) { self.sha256 = sha256; self.taskIDs = taskIDs; self.at = at }
}

// MARK: - State

/// Everything in `flow.json`.
public struct TBDFlowState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var tasks: [TBDFlowTask]
    public var reminders: [TBDFlowReminder]
    public var focus: TBDFlowFocus?
    public var settings: TBDFlowSettings
    /// cardID → label.
    public var cardLabels: [String: TBDFlowCardLabel]
    /// idempotency key → record.
    public var imports: [String: TBDFlowImportRecord]
    /// Set once the read-only Tasklist import ran.
    public var tasklistImportedAt: Date?

    public init(version: Int = TBDFlowState.currentVersion, tasks: [TBDFlowTask] = [], reminders: [TBDFlowReminder] = [],
                focus: TBDFlowFocus? = nil, settings: TBDFlowSettings = TBDFlowSettings(),
                cardLabels: [String: TBDFlowCardLabel] = [:], imports: [String: TBDFlowImportRecord] = [:],
                tasklistImportedAt: Date? = nil) {
        self.version = version; self.tasks = tasks; self.reminders = reminders; self.focus = focus; self.settings = settings
        self.cardLabels = cardLabels; self.imports = imports; self.tasklistImportedAt = tasklistImportedAt
    }

    /// Tolerant of a missing section (an older or hand-edited file); a wrong type in `tasks` is a corrupt file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        tasks = try c.decodeIfPresent([TBDFlowTask].self, forKey: .tasks) ?? []
        reminders = try c.decodeIfPresent([TBDFlowReminder].self, forKey: .reminders) ?? []
        focus = try c.decodeIfPresent(TBDFlowFocus.self, forKey: .focus)
        settings = try c.decodeIfPresent(TBDFlowSettings.self, forKey: .settings) ?? TBDFlowSettings()
        cardLabels = try c.decodeIfPresent([String: TBDFlowCardLabel].self, forKey: .cardLabels) ?? [:]
        imports = try c.decodeIfPresent([String: TBDFlowImportRecord].self, forKey: .imports) ?? [:]
        tasklistImportedAt = try c.decodeIfPresent(Date.self, forKey: .tasklistImportedAt)
    }
}

/// The JSON settings for `flow.json`: ISO dates, sorted keys (stable diffs), no slash escaping.
public enum TBDFlowCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(TBDFlowISO.string(date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = TBDFlowISO.date(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
            }
            return date
        }
        return d
    }
}
