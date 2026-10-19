import Foundation

/// Flow's Task Board source (F4, C282, DESIGN-FLOW.md 2.3): pure rules. The network part is the Chat helper
/// (`flowTaskBoardList`, `flowTaskBoardComplete`); the app only wires them. Nothing here creates a Task Board issue (Q1).

// MARK: - Issues

public enum TBDFlowIssueStatus: String, Equatable, Sendable { case inProgress = "in_progress", todo }

/// One of the owner's open issues, as the helper reduces it.
public struct TBDFlowTaskBoardIssue: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var project: String
    public var status: TBDFlowIssueStatus
    public var priority: String
    public var ready: Bool

    public init(id: String, title: String, summary: String = "", project: String = "", status: TBDFlowIssueStatus = .todo,
                priority: String = "medium", ready: Bool = true) {
        self.id = id; self.title = title; self.summary = summary; self.project = project; self.status = status
        self.priority = priority; self.ready = ready
    }

    init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any], let id = o["id"] as? String, !id.isEmpty,
              let title = o["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = o["status"] as? String, let status = TBDFlowIssueStatus(rawValue: raw) else { return nil }
        self.init(id: id, title: title, summary: o["summary"] as? String ?? "", project: o["project"] as? String ?? "",
                  status: status, priority: o["priority"] as? String ?? "medium", ready: o["ready"] as? Bool ?? false)
    }

    /// What the sheet offers: in progress, and todo issues that are ready (every dependency done).
    public var isPickable: Bool { status == .inProgress || ready }
}

/// The helper's answer to `flowTaskBoardList`.
public struct TBDFlowTaskBoardList: Equatable, Sendable {
    public var available: Bool
    public var reason: String?
    public var issues: [TBDFlowTaskBoardIssue]

    public init(available: Bool, reason: String? = nil, issues: [TBDFlowTaskBoardIssue] = []) {
        self.available = available; self.reason = reason; self.issues = issues
    }

    /// nil when the value is not the helper's shape (the caller treats that as a failed check).
    public init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any], let available = o["available"] as? Bool else { return nil }
        let rows = (o["issues"] as? [Any] ?? []).compactMap { TBDFlowTaskBoardIssue(helperValue: $0) }
        self.init(available: available, reason: o["reason"] as? String, issues: rows)
    }

    /// In progress first, then ready issues; the order inside a group is the helper's (highest priority first).
    public var pickable: [TBDFlowTaskBoardIssue] {
        issues.filter { $0.status == .inProgress && $0.isPickable } + issues.filter { $0.status == .todo && $0.isPickable }
    }
}

// MARK: - Source decision

/// Which list Flow shows.
public enum TBDFlowSourceMode: Equatable, Sendable {
    case taskBoard
    case local(TBDFlowLocalReason)

    public var isTaskBoard: Bool { self == .taskBoard }
}

/// Why Flow keeps its list on this Mac.
public enum TBDFlowLocalReason: Equatable, Sendable {
    /// The plan is not known yet (unknown never locks) or the list has not answered yet: local list, quiet note.
    case checking
    /// Task Board is not paid for (or nobody is signed in).
    case notLicensed
    /// Task Board is paid for but not installed in this workspace.
    case installNeeded
    /// Paid for, but TBD's agent is not connected to the workspace.
    case notConnected
    /// Paid for and connected, but the owner did not grant the agent Task Board: the helper's sentence.
    case notGranted(String)
    /// The check failed (timeout, pause...): the person-facing sentence.
    case failed(String)
}

/// What the last `flowTaskBoardList` check said.
public enum TBDFlowTaskBoardProbe: Equatable, Sendable {
    case unanswered
    case available
    case unavailable(String)
    case failed(String)
}

public enum TBDFlowSource {
    /// `.taskBoard` only when (a) the plan says Task Board is licensed for the workspace, (b) TBD's agent is connected and
    /// (c) the list check answered available. An unknown plan never locks (C282): when TBD's agent is connected and the
    /// relay lists Task Board's tool and answers, that grant is proof enough; otherwise it reads "checking" and the local
    /// list stays.
    public static func decide(access: TBDAppAccess, agentConnected: Bool, probe: TBDFlowTaskBoardProbe) -> TBDFlowSourceMode {
        switch access {
        case .locked: return .local(.notLicensed)
        case .install: return .local(.installNeeded)
        case .unknown: return agentConnected && probe == .available ? .taskBoard : .local(.checking)
        case .unlocked:
            guard agentConnected else { return .local(.notConnected) }
            switch probe {
            case .unanswered: return .local(.checking)
            case .available: return .taskBoard
            case .unavailable(let reason): return .local(.notGranted(reason))
            case .failed(let message): return .local(.failed(message))
            }
        }
    }

    public static let notLicensedNotice = "Task list from Task Board: available with Task Board. Until then TBD keeps this list on this Mac."
    public static let installNotice = "Task list from Task Board: install Task Board in Portal. Until then TBD keeps this list on this Mac."
    public static let checkingNotice = "Checking Task Board…"
    /// The helper's sentence for a list call that waits for the owner (same text as `listWaiting` in the Chat helper).
    public static let listWaitingNotice = "Task Board is waiting for the owner to approve sharing your list. Check again after the owner approves."
    public static let notConnectedNotice = "Connect TBD's agent to your workspace first (Chat › agent panel › Connect)."

    /// The line above the plan; nil when nothing needs saying.
    public static func notice(_ mode: TBDFlowSourceMode) -> String? {
        guard case .local(let reason) = mode else { return nil }
        switch reason {
        case .checking: return checkingNotice
        case .notLicensed: return notLicensedNotice
        case .installNeeded: return installNotice
        case .notConnected: return notConnectedNotice
        case .notGranted(let sentence): return sentence
        case .failed(let sentence): return sentence
        }
    }
}

// MARK: - Plan paste linking

public enum TBDFlowTaskBoardLinker {
    /// Title as compared: no case, accents or width, spaces collapsed, no edge punctuation.
    public static func normalize(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let words = folded.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?-–—"))
    }

    /// Links each draft whose normalized title equals exactly one open issue; the draft then takes the issue's id,
    /// project and title. A title that two issues share stays local (no guessing), as does the second line for an
    /// issue already linked. Other drafts are unchanged. No issue is ever created.
    public static func link(_ drafts: [TBDFlowTaskDraft], issues: [TBDFlowTaskBoardIssue]) -> [TBDFlowTaskDraft] {
        var byTitle: [String: [TBDFlowTaskBoardIssue]] = [:]
        for issue in issues { byTitle[normalize(issue.title), default: []].append(issue) }
        var used = Set<String>()
        return drafts.map { draft in
            var out = draft
            out.taskBoardID = nil
            out.taskBoardProject = nil
            let key = normalize(draft.title)
            guard !key.isEmpty, let matches = byTitle[key], matches.count == 1, let issue = matches.first, !used.contains(issue.id) else { return out }
            used.insert(issue.id)
            out.title = issue.title
            out.taskBoardID = issue.id
            out.taskBoardProject = issue.project.isEmpty ? nil : issue.project
            return out
        }
    }
}

// MARK: - Time range field (Add from Task Board sheet)

public enum TBDFlowTimeRange: Equatable, Sendable {
    case none
    case range(Date, Date)
    case invalid(String)

    public static let invalidMessage = "Write the time as 09:40 – 11:30 (24 hours), or leave it empty."

    /// "09:40 – 11:30", "9:40-11:30", "09:40 to 11:30"; empty = no time. The end must follow the start.
    public static func parse(_ text: String, day: Date, calendar: Calendar) -> TBDFlowTimeRange {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .none }
        let normalized = trimmed.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: " to ", with: "-")
        let parts = normalized.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = clock(parts[0]), let b = clock(parts[1]),
              let start = calendar.date(bySettingHour: a.0, minute: a.1, second: 0, of: day),
              let end = calendar.date(bySettingHour: b.0, minute: b.1, second: 0, of: day) else { return .invalid(invalidMessage) }
        guard end > start else { return .invalid("The end must come after the start.") }
        return .range(start, end)
    }

    private static func clock(_ text: String) -> (Int, Int)? {
        let p = text.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, (1...2).contains(p[0].count), p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}

// MARK: - Result text

public enum TBDFlowTaskBoardResult {
    /// The result Flow writes when the person marks an issue done: "Done — tracked in TBD Flow, 45 min on plan".
    public static func text(minutesOnPlan: Int) -> String {
        "Done — tracked in TBD Flow, \(max(0, minutesOnPlan)) min on plan"
    }
}
