import Foundation

/// What the matcher needs to know about one Companion timeline card (DESIGN-FLOW.md 2.4).
public struct TBDFlowCardEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var start: Date
    public var end: Date
    public var title: String
    public var summary: String
    public var apps: [String]
    /// The card's category when Companion gave one ("Idle", "Break", "Work"…).
    public var category: String?
    public init(id: String, start: Date, end: Date, title: String, summary: String = "", apps: [String] = [], category: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.title = title; self.summary = summary; self.apps = apps
        self.category = category
    }
    public var minutes: Double { max(0, end.timeIntervalSince(start) / 60) }
}

/// A proposal from the rules: the label, the task for `.onPlan`, and the word score behind it.
public struct TBDFlowMatch: Equatable, Sendable {
    public var label: TBDFlowLabel
    public var taskID: String?
    public var score: Double
}

/// Minutes of today by label. `outsideMinutes` = cards before the first task or after the last (not counted as off plan).
public struct TBDFlowTotals: Equatable, Sendable {
    public var onPlanMinutes: Double = 0
    public var offPlanMinutes: Double = 0
    public var restMinutes: Double = 0
    public var outsideMinutes: Double = 0
    public init() {}
}

/// The rule matcher for plan vs actual (third in the order person > model > rule). Deterministic; the thresholds are
/// named constants so the tests pin them.
public enum TBDFlowMatcher {
    /// A card is "in" a timebox (or a break) when at least this share of the card lies inside it.
    public static let timeboxOverlapFraction = 0.5
    /// Weight of a shared word that is in the task title, and of one that is only in its notes or subtasks.
    public static let titleWordWeight = 1.0
    public static let detailWordWeight = 0.5
    /// Score needed when the card is in the task's timebox: one title word, or two words of the notes.
    public static let timeboxWordThreshold = 1.0
    /// Score needed without a timebox match: two title words, or one title word and two of the notes, and so on.
    public static let strongWordThreshold = 2.0
    /// Words shorter than this are ignored.
    public static let minWordLength = 3
    /// A category word that means the person was not working.
    public static let restCategoryWords: Set<String> = ["idle", "break", "rest", "away", "lunch", "sleep", "locked", "lock"]
    static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "into", "onto", "over", "under", "about", "have", "has", "had", "are",
        "was", "were", "been", "being", "you", "your", "our", "out", "not", "but", "can", "will", "all", "any", "new", "use", "using",
        "used", "its", "his", "her", "their", "then", "than", "just", "also", "more", "most", "some", "such", "only", "very",
        "page", "tab", "tabs", "window", "app", "screen", "work", "working", "task", "tasks", "open", "file", "files", "untitled",
        "http", "https", "www", "com", "while", "when", "what", "which", "who", "how", "per", "via", "etc",
    ]

    // MARK: Words

    /// Lowercase words of `text`, stop words and short words removed, plural endings stripped.
    public static func words(_ text: String) -> Set<String> {
        var out = Set<String>()
        var current = ""
        func flush() {
            if current.count >= minWordLength, !stopWords.contains(current) { out.insert(stem(current)) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return out
    }

    /// `ies` → `y`, `sses` → `ss`, `xes`/`ches`/`shes`/`zes` → drop `es`, a final `s` dropped (not `ss`, `us`, `is`).
    static func stem(_ w: String) -> String {
        if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
        if w.count > 5, w.hasSuffix("sses") { return String(w.dropLast(2)) }
        if w.count > 4, ["xes", "ches", "shes", "zes"].contains(where: w.hasSuffix) { return String(w.dropLast(2)) }
        if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss"), !w.hasSuffix("us"), !w.hasSuffix("is") { return String(w.dropLast()) }
        return w
    }

    /// Score of a card against a task: shared title words count `titleWordWeight`, shared notes or subtask words
    /// `detailWordWeight`.
    public static func wordScore(card: TBDFlowCardEvidence, task: TBDFlowTask) -> Double {
        let cardWords = words(card.title + " " + card.summary)
        let titleWords = words(task.title)
        let detailWords = words(task.notes + " " + task.subtasks.map(\.title).joined(separator: " ")).subtracting(titleWords)
        return Double(cardWords.intersection(titleWords).count) * titleWordWeight
            + Double(cardWords.intersection(detailWords).count) * detailWordWeight
    }

    // MARK: Time

    /// Share (0...1) of the card that lies inside [start, end).
    static func overlapFraction(card: TBDFlowCardEvidence, start: Date, end: Date) -> Double {
        let length = card.end.timeIntervalSince(card.start)
        if length <= 0 { return start <= card.start && card.start < end ? 1 : 0 }
        let overlap = min(card.end, end).timeIntervalSince(max(card.start, start))
        return max(0, min(1, overlap / length))
    }

    // MARK: Proposal

    /// The label the rules propose for one card, or nil when the card is outside the plan (entirely before the first task
    /// start or after the last task end) or there is no plan. Cancelled tasks are ignored. Order:
    /// 1. outside the plan → nil
    /// 2. rest: the card is in a break task, or its category means idle or break
    /// 3. on plan: the best-scoring task whose timebox holds the card with score >= `timeboxWordThreshold`, or any task with
    ///    score >= `strongWordThreshold`; a tie goes to the task whose timebox holds the card, then to the earlier task
    /// 4. off plan
    public static func propose(card: TBDFlowCardEvidence, tasks: [TBDFlowTask]) -> TBDFlowMatch? {
        let plan = tasks.filter { $0.status != .cancelled }
        guard !plan.isEmpty else { return nil }
        let starts = plan.compactMap(\.startAt)
        let ends = plan.compactMap { $0.endAt ?? $0.startAt }
        if let first = starts.min(), card.end <= first { return nil }
        if let last = ends.max(), card.start >= last { return nil }

        let inBreak = plan.contains { t in
            guard TBDFlowSession.isBreak(t), let s = t.startAt, let e = t.endAt else { return false }
            return overlapFraction(card: card, start: s, end: e) >= timeboxOverlapFraction
        }
        let categoryWords = Set((card.category ?? "").lowercased().split { !$0.isLetter }.map(String.init))
        if inBreak || !categoryWords.isDisjoint(with: restCategoryWords) {
            return TBDFlowMatch(label: .rest, taskID: nil, score: 0)
        }

        struct Candidate { var task: TBDFlowTask; var score: Double; var inTimebox: Bool }
        let candidates: [Candidate] = plan.filter { !TBDFlowSession.isBreak($0) }.compactMap { t in
            var inTimebox = false
            if let s = t.startAt, let e = t.endAt { inTimebox = overlapFraction(card: card, start: s, end: e) >= timeboxOverlapFraction }
            let score = wordScore(card: card, task: t)
            guard (inTimebox && score >= timeboxWordThreshold) || score >= strongWordThreshold else { return nil }
            return Candidate(task: t, score: score, inTimebox: inTimebox)
        }
        let best = candidates.enumerated().max { a, b in
            if a.element.score != b.element.score { return a.element.score < b.element.score }
            if a.element.inTimebox != b.element.inTimebox { return !a.element.inTimebox }
            return a.offset > b.offset // earlier in the list wins
        }?.element
        if let best { return TBDFlowMatch(label: .onPlan, taskID: best.task.id, score: best.score) }
        return TBDFlowMatch(label: .offPlan, taskID: nil, score: 0)
    }

    /// `propose` as a stored label (`by: .rule`).
    public static func ruleLabel(for card: TBDFlowCardEvidence, tasks: [TBDFlowTask], at: Date) -> TBDFlowCardLabel? {
        guard let m = propose(card: card, tasks: tasks) else { return nil }
        return TBDFlowCardLabel(cardID: card.id, label: m.label, taskID: m.taskID, by: .rule, at: at)
    }

    // MARK: Effective labels and minutes

    /// The label that counts for a card: the stored label (a person's correction, else the model's, else a stored rule
    /// label), else what the rules propose now. nil = outside the plan.
    public static func effectiveLabel(for card: TBDFlowCardEvidence, stored: [String: TBDFlowCardLabel], tasks: [TBDFlowTask],
                                      at: Date = Date()) -> TBDFlowCardLabel? {
        stored[card.id] ?? ruleLabel(for: card, tasks: tasks, at: at)
    }

    /// Minutes on plan per task id. `tasks` lets cards without a stored label fall back to the rules.
    public static func minutesPerTask(labels: [String: TBDFlowCardLabel], cards: [TBDFlowCardEvidence], tasks: [TBDFlowTask] = []) -> [String: Double] {
        var out: [String: Double] = [:]
        for card in cards {
            guard let l = effectiveLabel(for: card, stored: labels, tasks: tasks), l.label == .onPlan, let id = l.taskID else { continue }
            out[id, default: 0] += card.minutes
        }
        return out
    }

    /// On plan, off plan, rest and outside-the-plan minutes for the cards.
    public static func totals(labels: [String: TBDFlowCardLabel], cards: [TBDFlowCardEvidence], tasks: [TBDFlowTask] = []) -> TBDFlowTotals {
        var t = TBDFlowTotals()
        for card in cards {
            switch effectiveLabel(for: card, stored: labels, tasks: tasks)?.label {
            case .onPlan?: t.onPlanMinutes += card.minutes
            case .offPlan?: t.offPlanMinutes += card.minutes
            case .rest?: t.restMinutes += card.minutes
            case nil: t.outsideMinutes += card.minutes
            }
        }
        return t
    }
}
