import CryptoKit
import Foundation

/// One task a pasted plan produced, before it is saved.
public struct TBDFlowTaskDraft: Codable, Equatable, Sendable {
    public var title: String
    public var notes: String
    /// Subtask titles, in order.
    public var subtasks: [String]
    /// `yyyy-MM-dd`.
    public var day: String
    public var startAt: Date?
    public var endAt: Date?
    /// F4: the Task Board issue this line is linked to (a pasted line whose title equals an open issue of the owner).
    /// nil = the task stays on this Mac.
    public var taskBoardID: String?
    public var taskBoardProject: String?

    public init(title: String, notes: String = "", subtasks: [String] = [], day: String, startAt: Date? = nil, endAt: Date? = nil,
                taskBoardID: String? = nil, taskBoardProject: String? = nil) {
        self.title = title; self.notes = notes; self.subtasks = subtasks; self.day = day; self.startAt = startAt; self.endAt = endAt
        self.taskBoardID = taskBoardID; self.taskBoardProject = taskBoardProject
    }

    /// Length of the timebox in whole minutes; 0 when unknown.
    public var durationMinutes: Int {
        guard let startAt, let endAt, endAt > startAt else { return 0 }
        return Int(endAt.timeIntervalSince(startAt) / 60)
    }
}

/// Which parser produced a preview.
public enum TBDFlowPlanEngine: String, Codable, Sendable { case strict, lenient }

public struct TBDFlowPlanPreview: Equatable, Sendable {
    public var engine: TBDFlowPlanEngine
    public var drafts: [TBDFlowTaskDraft]
    public var warnings: [String]
    /// Lenient only: why the strict format did not fit (for "Not in the agent format: Line 2: …").
    public var strictError: String?
    /// The lenient parser guesses; the person must look before saving.
    public var requiresReview: Bool
}

/// A plan the parser refused, with the text the UI shows (names the line where there is one).
public struct TBDFlowPlanError: Error, Equatable, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Two parsers for a pasted day plan (DESIGN-FLOW.md 2.2).
///
/// - `parseSchedule`: the deterministic `agent-schedule-v1` contract, a port of Tasklist `schedule_ingest.parse_schedule`.
///   One task per unindented line: `HH:MM[-HH:MM] Title` or `TODO Title`; an indented `- x` is a subtask and `> x` a note
///   of the task above. 1...30 tasks, at most 6000 characters, end after start, and a wall time that does not exist or
///   happens twice (daylight saving) is refused. Anything else is an error that names the line.
/// - `parseLenient`: the fallback for pasted lists, a port of `server.py` `draft()`. Bullets and numbering are stripped, a
///   leading `HH:MM[-HH:MM]` is a timebox, indented lines are subtasks. It guesses, so it warns and asks for review.
public enum TBDFlowPlanParser {
    public static let format = "agent-schedule-v1"
    public static let maxCharacters = 6000
    public static let maxTasks = 30
    public static let maxLenientCharacters = 30_000
    public static let maxCommitDrafts = 200

    // The strict line: time(s) or TODO, then the title (`schedule_ingest.py`). `-` or `–` between the times.
    private static let strictLine = try! NSRegularExpression(
        pattern: #"^(?:(\d{1,2}:\d{2})(?:\s*[-–]\s*(\d{1,2}:\d{2}))?|TODO)\s+(.+)$"#)
    // `server.py` draft(): bullet or number prefix, then optional times.
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(?:[-*•]|\d+[.)])\s*"#)
    private static let subBullet = try! NSRegularExpression(pattern: #"^\s*[-*•]\s*"#)
    private static let lenientLine = try! NSRegularExpression(
        pattern: #"^(\d{1,2}):(\d{2})(?:\s*[-–]\s*(\d{1,2}):(\d{2}))?\s+(.+)$"#)

    // MARK: Strict

    public static func parseSchedule(text: String, day: String, timeZone: TimeZone) throws -> [TBDFlowTaskDraft] {
        guard let dayParts = TBDFlowDay.components(day) else { throw TBDFlowPlanError("day must be an ISO date (yyyy-MM-dd)") }
        let size = text.unicodeScalars.count
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, size <= maxCharacters else {
            throw TBDFlowPlanError("Schedule requires 1–6000 characters")
        }
        var result: [TBDFlowTaskDraft] = []
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        for (offset, substring) in lines.enumerated() {
            let number = offset + 1
            let line = String(substring)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if line.first?.isWhitespace == true {
                guard !result.isEmpty else { throw TBDFlowPlanError("Line \(number): detail has no parent task") }
                let detail = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.hasPrefix("- ") {
                    result[result.count - 1].subtasks.append(String(detail.dropFirst(2)))
                } else if detail.hasPrefix("> ") {
                    let note = String(detail.dropFirst(2))
                    result[result.count - 1].notes += (result[result.count - 1].notes.isEmpty ? "" : "\n") + note
                } else {
                    throw TBDFlowPlanError("Line \(number): indented detail must start with - or >")
                }
                continue
            }
            guard let m = strictLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                throw TBDFlowPlanError("Line \(number): use HH:MM[-HH:MM] Title or TODO Title; no headings")
            }
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: line).map { String(line[$0]) } }
            let title = (group(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.count > TBDFlowTask.maxTitle {
                throw TBDFlowPlanError("Line \(number): Title required (max 500 characters)")
            }
            var draft = TBDFlowTaskDraft(title: title, day: day)
            var start: Date?
            if let s = group(1) {
                start = try wallTime(s, day: dayParts, zone: timeZone, line: number)
                draft.startAt = start
            }
            if let e = group(2), let start {
                let end = try wallTime(e, day: dayParts, zone: timeZone, line: number)
                if end <= start { throw TBDFlowPlanError("Line \(number): end must follow start on the same day") }
                draft.endAt = end
            }
            result.append(draft)
        }
        guard (1...maxTasks).contains(result.count) else { throw TBDFlowPlanError("Schedule must have 1–30 tasks") }
        for (i, d) in result.enumerated() {
            if d.subtasks.count > TBDFlowTask.maxSubtasks { throw TBDFlowPlanError("Task \(i + 1): Invalid subtasks") }
            if d.notes.count > TBDFlowTask.maxNotes { throw TBDFlowPlanError("Task \(i + 1): Notes too long") }
        }
        return result
    }

    /// `H:MM` or `HH:MM` on `day` in `zone`. Refuses an hour or minute out of range and a wall time that does not exist
    /// or happens twice (the Tasklist message, with the line).
    private static func wallTime(_ value: String, day: (year: Int, month: Int, day: Int), zone: TimeZone, line: Int) throws -> Date {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else {
            throw TBDFlowPlanError("Line \(line): Invalid time \(value)")
        }
        guard let date = exactInstant(day: day, hour: h, minute: m, zone: zone) else {
            throw TBDFlowPlanError("Line \(line): Ambiguous or nonexistent DST time; use reviewed task API with explicit offsets")
        }
        return date
    }

    /// The one instant whose wall clock in `zone` reads `day` `hour:minute`; nil when there is none (daylight-saving gap)
    /// or two (the repeated hour).
    static func exactInstant(day: (year: Int, month: Int, day: Int), hour: Int, minute: Int, zone: TimeZone) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let wall = utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)) else { return nil }
        // The offset can only change near the wall time; look a day on each side to get both possible offsets.
        let offsets = Set([-86400.0, 86400.0].map { zone.secondsFromGMT(for: wall.addingTimeInterval($0)) })
        let valid = offsets.compactMap { offset -> Date? in
            let instant = wall.addingTimeInterval(-Double(offset))
            return zone.secondsFromGMT(for: instant) == offset ? instant : nil
        }
        return valid.count == 1 ? valid[0] : nil
    }

    // MARK: Lenient

    /// `server.py` `draft()`: "one line per task; explicit times only, always preview".
    public static func parseLenient(text: String, day: String, timeZone: TimeZone) throws -> TBDFlowPlanPreview {
        guard let dayParts = TBDFlowDay.components(day) else { throw TBDFlowPlanError("day must be an ISO date (yyyy-MM-dd)") }
        if text.unicodeScalars.count > maxLenientCharacters { throw TBDFlowPlanError("Text limit: 30000 characters") }
        var out: [TBDFlowTaskDraft] = []
        var warnings: [String] = []
        func strip(_ r: NSRegularExpression, _ s: String) -> String {
            r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for substring in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(substring)
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if line.first?.isWhitespace == true, !out.isEmpty {
                let sub = strip(subBullet, line)
                if !sub.isEmpty { out[out.count - 1].subtasks.append(sub) }
                continue
            }
            let title = strip(bullet, line)
            if title.isEmpty { warnings.append("Skipped an empty line"); continue }
            var draft = TBDFlowTaskDraft(title: title, day: day)
            if let m = lenientLine.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) {
                func group(_ i: Int) -> String? { Range(m.range(at: i), in: title).map { String(title[$0]) } }
                if let start = lenientInstant(group(1), group(2), dayParts, timeZone) {
                    // The title loses its times even when the end is wrong (as in Python).
                    draft.title = group(5) ?? title
                    draft.startAt = start.date
                    if start.daylightSaving { warnings.append("Check time (daylight saving): " + title) }
                    if group(3) != nil {
                        if let end = lenientInstant(group(3), group(4), dayParts, timeZone), end.date > start.date {
                            draft.endAt = end.date
                            if end.daylightSaving { warnings.append("Check time (daylight saving): " + title) }
                        } else {
                            warnings.append("Check time: " + title)
                        }
                    }
                } else {
                    warnings.append("Check time: " + title)
                }
            }
            if draft.title.count > TBDFlowTask.maxTitle {
                warnings.append("Title shortened to 500 characters: " + String(draft.title.prefix(40)) + "…")
                draft.title = String(draft.title.prefix(TBDFlowTask.maxTitle))
            }
            out.append(draft)
        }
        if out.isEmpty { throw TBDFlowPlanError("Paste at least one task") }
        if out.count > maxCommitDrafts { throw TBDFlowPlanError("Too many tasks (max 200)") }
        warnings.append("Review dates and task boundaries. This parser does not infer plans from prose.")
        return TBDFlowPlanPreview(engine: .lenient, drafts: out, warnings: warnings, strictError: nil, requiresReview: true)
    }

    /// nil when the hour or minute is out of range; `daylightSaving` when the wall time does not exist or happens twice
    /// (the calendar's reading is used and the caller warns).
    private static func lenientInstant(_ h: String?, _ m: String?, _ day: (year: Int, month: Int, day: Int), _ zone: TimeZone)
        -> (date: Date, daylightSaving: Bool)? {
        guard let h, let m, let hour = Int(h), let minute = Int(m), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if let exact = exactInstant(day: day, hour: hour, minute: minute, zone: zone) { return (exact, false) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        guard let d = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)) else { return nil }
        return (d, true)
    }

    // MARK: Preview

    /// Strict first; if the text is not in the `agent-schedule-v1` format, the lenient parser, and the preview says which.
    public static func preview(text: String, day: String, timeZone: TimeZone) throws -> TBDFlowPlanPreview {
        do {
            let drafts = try parseSchedule(text: text, day: day, timeZone: timeZone)
            return TBDFlowPlanPreview(engine: .strict, drafts: drafts, warnings: [], strictError: nil, requiresReview: false)
        } catch let strict as TBDFlowPlanError {
            var lenient = try parseLenient(text: text, day: day, timeZone: timeZone)
            lenient.strictError = strict.message
            return lenient
        }
    }

    // MARK: Idempotency

    /// SHA-256 (hex) of `{day, format, text, timezone}` as sorted-key JSON: the same source gives the same hash, any
    /// change of text, day or time zone gives another (`server.py` `digest`).
    public static func payloadHash(format: String, text: String, day: String, timeZone: TimeZone) -> String {
        struct Payload: Encodable { var format: String; var text: String; var day: String; var timezone: String }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Payload(format: format, text: text, day: day, timezone: timeZone.identifier))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a `commit` did.
public struct TBDFlowCommitResult: Equatable, Sendable {
    /// Ids of the tasks, in plan order (the original ids on a replay).
    public var taskIDs: [String]
    /// The tasks now in the list (a replay returns those that still exist).
    public var tasks: [TBDFlowTask]
    /// true when the same key and payload had been committed before: nothing was added.
    public var replayed: Bool
}

extension TBDFlowStore {
    /// Saves a previewed plan as tasks, all or none. Idempotent per key (1...200 characters): the same key with the same
    /// `payloadHash` returns the first result and adds nothing; the same key with another hash throws
    /// `.idempotencyConflict` (409 in the Tasklist API). A new key appends; it never replaces earlier tasks.
    @discardableResult
    public func commit(drafts: [TBDFlowTaskDraft], idempotencyKey: String, payloadHash: String) throws -> TBDFlowCommitResult {
        guard (1...200).contains(idempotencyKey.count) else { throw TBDFlowError.idempotencyKeyRequired }
        guard (1...TBDFlowPlanParser.maxCommitDrafts).contains(drafts.count) else { throw TBDFlowError.invalid("Expected 1–200 drafts") }
        return try mutate { state, now in
            if let old = state.imports[idempotencyKey] {
                guard old.sha256 == payloadHash else { throw TBDFlowError.idempotencyConflict }
                let ids = Set(old.taskIDs)
                return TBDFlowCommitResult(taskIDs: old.taskIDs, tasks: state.tasks.filter { ids.contains($0.id) }, replayed: true)
            }
            var created: [TBDFlowTask] = []
            for d in drafts {
                let task = TBDFlowTask(
                    id: newID(), title: d.title, notes: d.notes,
                    subtasks: d.subtasks.map { TBDFlowSubtask(id: newID(), title: String($0.prefix(TBDFlowTask.maxTitle))) },
                    day: d.day, startAt: d.startAt, endAt: d.endAt, source: d.taskBoardID == nil ? .local : .taskBoard,
                    taskBoardID: d.taskBoardID, taskBoardProject: d.taskBoardID == nil ? nil : d.taskBoardProject, createdAt: now)
                try task.validate()
                created.append(task)
            }
            state.tasks.append(contentsOf: created)
            state.imports[idempotencyKey] = TBDFlowImportRecord(sha256: payloadHash, taskIDs: created.map(\.id), at: now)
            return TBDFlowCommitResult(taskIDs: created.map(\.id), tasks: created, replayed: false)
        }
    }
}
