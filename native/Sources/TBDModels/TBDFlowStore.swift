import Foundation

/// What one `tick` changed.
public struct TBDFlowTickResult: Equatable, Sendable {
    /// Reminders created by this tick (already stored).
    public var newReminders: [TBDFlowReminder]
    /// The timer, when this tick finished it.
    public var finishedFocus: TBDFlowFocus?
    public var changed: Bool { !newReminders.isEmpty || finishedFocus != nil }
}

/// The Flow list on disk (DESIGN-FLOW.md 2.2): tasks, reminders, focus timer, settings, card labels and plan imports in one
/// JSON file. Replaces the Tasklist service of v1 (`server.py`); the rules are ported, the HTTP layer is not.
///
/// - Thread-safe: one lock around the state, so the @MainActor UI and a background `tick` may both call it. Every method
///   is atomic: the new state is written first and replaces the old one only if the write worked.
/// - The file is written atomically (temp file in the same folder, then rename), mode 0600, in a folder of mode 0700.
/// - A file that cannot be read is moved aside to `flow.json.corrupt-<timestamp>` (renamed, never deleted) and Flow
///   starts empty; `corruptBackupURL` tells the app so it can say so. If the file cannot be moved aside, the store
///   refuses every write (`isLockedByUnreadableFile`): it never overwrites the unreadable file.
/// - The clock and the id generator are injected, so tests do not depend on the real date.
public final class TBDFlowStore: @unchecked Sendable {
    /// `~/Library/Application Support/<TBD data folder>/Companion/flow.json`. The data folder is `TBDIdentity.dataFolder`
    /// (`com.tealbrick.desktop`, the dev copy has its own), never the archived v1 folder `TBD`.
    public static var defaultURL: URL {
        TBDIdentity.applicationSupport("Companion").appendingPathComponent("flow.json")
    }

    /// A reminder that was acknowledged this long ago, for a task that is gone or finished, is dropped by `tick`.
    public static let reminderRetention: TimeInterval = 14 * 24 * 3600

    /// A reminder whose due time is more than this long before `now` when `tick` makes it is stored already acknowledged:
    /// no catch-up storm after a paste, an import or a relaunch.
    public static let staleReminderAge: TimeInterval = 15 * 60

    public let url: URL
    private let clock: @Sendable () -> Date
    private let makeID: @Sendable () -> String
    private let lock = NSLock()
    private var current: TBDFlowState
    private var movedAside: URL?
    private var unreadableAndKept = false

    public init(url: URL = TBDFlowStore.defaultURL, clock: @escaping @Sendable () -> Date = { Date() },
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }) {
        self.url = url
        self.clock = clock
        self.makeID = makeID
        self.current = TBDFlowState()
        self.current = loadFromDisk()
    }

    /// A copy of the state.
    public var state: TBDFlowState { locked { current } }
    /// Where the unreadable file went, when the last load moved one aside.
    public var corruptBackupURL: URL? { locked { movedAside } }
    /// The list file could not be read and could not be moved aside: the list is empty and every write is refused.
    public var isLockedByUnreadableFile: Bool { locked { unreadableAndKept } }

    // MARK: Disk

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func loadFromDisk() -> TBDFlowState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return TBDFlowState() }
        if let data = try? Data(contentsOf: url),
           let decoded = try? TBDFlowCoding.decoder().decode(TBDFlowState.self, from: data),
           decoded.version <= TBDFlowState.currentVersion {
            return decoded
        }
        // Unreadable, not JSON of our shape, or written by a newer build: keep the bytes, start empty.
        let stamp = Self.stamp(clock())
        var target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp)
        var n = 1
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp + "-\(n)")
        }
        if (try? fm.moveItem(at: url, to: target)) != nil { movedAside = target } else { unreadableAndKept = true }
        return TBDFlowState()
    }

    private static func stamp(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian)
        var utc = c
        utc.timeZone = TimeZone(identifier: "UTC")!
        let p = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0, p.second ?? 0)
    }

    private func write(_ state: TBDFlowState) throws {
        if unreadableAndKept {
            throw TBDFlowError.storage("Flow could not read the list file and could not move it aside, so it does not save over it")
        }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            }
            let data = try TBDFlowCoding.encoder().encode(state)
            let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw TBDFlowError.storage("Flow could not save the list")
            }
            if rename(temp.path, url.path) != 0 {
                try? fm.removeItem(at: temp) // our own temp file
                throw TBDFlowError.storage("Flow could not save the list")
            }
        } catch let e as TBDFlowError {
            throw e
        } catch {
            throw TBDFlowError.storage("Flow could not save the list: \(error.localizedDescription)")
        }
    }

    /// Runs `body` on a copy of the state; if it changed anything, writes the file and then swaps the copy in.
    /// Internal so the plan commit (another file) uses the same rule.
    @discardableResult
    func mutate<T>(now override: Date? = nil, _ body: (inout TBDFlowState, Date) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        var next = current
        let result = try body(&next, override ?? clock())
        if next != current {
            try write(next)
            current = next
        }
        return result
    }

    func newID() -> String { makeID() }

    // MARK: Tasks

    @discardableResult
    public func addTask(title: String, notes: String = "", subtasks: [String] = [], day: String, startAt: Date? = nil, endAt: Date? = nil,
                        source: TBDFlowTaskSource = .local, taskBoardID: String? = nil, taskBoardProject: String? = nil) throws -> TBDFlowTask {
        try mutate { state, now in
            let task = TBDFlowTask(
                id: makeID(), title: title, notes: notes,
                subtasks: subtasks.map { TBDFlowSubtask(id: makeID(), title: String($0.prefix(TBDFlowTask.maxTitle))) },
                day: day, startAt: startAt, endAt: endAt, source: source, taskBoardID: taskBoardID,
                taskBoardProject: taskBoardProject, createdAt: now)
            try task.validate()
            state.tasks.append(task)
            return task
        }
    }

    /// Changes a task through `change`. `id` and `createdAt` cannot change. `completedAt` follows the status. Done,
    /// cancelled, or a changed start or end acknowledges the task's reminders (`server.py` l.293-295).
    @discardableResult
    public func updateTask(id: String, _ change: (inout TBDFlowTask) -> Void) throws -> TBDFlowTask {
        try mutate { state, now in
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { throw TBDFlowError.notFound("Task") }
            let old = state.tasks[index]
            var task = old
            change(&task)
            task.id = old.id
            task.createdAt = old.createdAt
            task.updatedAt = now
            if task.status == .done || task.status == .cancelled { task.looksDoneAt = nil }
            if task.status == .done { task.completedAt = old.status == .done ? (old.completedAt ?? now) : now } else { task.completedAt = nil }
            if old.status == .done, task.status != .done, task.status != .cancelled { task.reopenedAt = now }
            try task.validate()
            state.tasks[index] = task
            if task.status == .done || task.status == .cancelled || task.startAt != old.startAt || task.endAt != old.endAt {
                Self.acknowledge(&state, taskID: id, at: now)
            }
            return task
        }
    }

    /// Deleting a task acknowledges its reminders.
    public func deleteTask(id: String) throws {
        try mutate { state, now in
            guard state.tasks.contains(where: { $0.id == id }) else { throw TBDFlowError.notFound("Task") }
            state.tasks.removeAll { $0.id == id }
            Self.acknowledge(&state, taskID: id, at: now)
        }
    }

    /// `.done` sets `completedAt`; any other status clears it.
    @discardableResult
    public func setStatus(id: String, _ status: TBDFlowTaskStatus) throws -> TBDFlowTask {
        try updateTask(id: id) { $0.status = status }
    }

    @discardableResult
    public func toggleSubtask(taskID: String, subtaskID: String) throws -> TBDFlowTask {
        var found = false
        let task = try updateTask(id: taskID) { task in
            if let i = task.subtasks.firstIndex(where: { $0.id == subtaskID }) {
                task.subtasks[i].done.toggle()
                found = true
            }
        }
        if !found { throw TBDFlowError.notFound("Subtask") }
        return task
    }

    // MARK: Looks done (F4)

    /// How long "Not yet" keeps the "Looks done" hint away from a task.
    public static let looksDoneRetry: TimeInterval = 30 * 60

    /// The observer thinks `id` is done. Sets the hint (nothing else changes: the person decides). Returns false and
    /// changes nothing when the task is gone or closed, the hint is already there, or the person said "Not yet" less
    /// than `looksDoneRetry` ago.
    @discardableResult
    public func markLooksDone(id: String, at when: Date? = nil) throws -> Bool {
        try mutate { state, now in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return false }
            let task = state.tasks[i]
            guard task.status != .done, task.status != .cancelled, task.looksDoneAt == nil else { return false }
            let t = when ?? now
            if let dismissed = task.looksDoneDismissedAt, t.timeIntervalSince(dismissed) < Self.looksDoneRetry { return false }
            state.tasks[i].looksDoneAt = t
            state.tasks[i].looksDoneDismissedAt = nil
            return true
        }
    }

    /// "Not yet": removes the hint and keeps it away for `looksDoneRetry`.
    public func dismissLooksDone(id: String) throws {
        try mutate { state, now in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { throw TBDFlowError.notFound("Task") }
            state.tasks[i].looksDoneAt = nil
            state.tasks[i].looksDoneDismissedAt = now
        }
    }

    public func task(id: String) -> TBDFlowTask? { locked { current.tasks.first { $0.id == id } } }

    /// Tasks of one day, by start time (tasks without a start first, as in v1).
    public func tasks(onDay day: String) -> [TBDFlowTask] {
        locked { current.tasks.filter { $0.day == day }.sorted { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) } }
    }

    private static func acknowledge(_ state: inout TBDFlowState, taskID: String, at now: Date) {
        for i in state.reminders.indices where state.reminders[i].taskID == taskID && state.reminders[i].acknowledgedAt == nil {
            state.reminders[i].acknowledgedAt = now
        }
    }

    // MARK: Settings

    @discardableResult
    public func updateSettings(_ change: (inout TBDFlowSettings) -> Void) throws -> TBDFlowSettings {
        try mutate { state, _ in
            var s = state.settings
            change(&s)
            try s.validate()
            state.settings = s
            return s
        }
    }

    // MARK: Focus timer

    /// Starts the timer. A focus for a task runs `min(settings.focusMinutes, minutes left in the timebox)`; when none
    /// are left it throws `.timeboxEnded` ("This timebox has ended. Replan it before starting focus."). A break runs
    /// `settings.breakMinutes`. `minutes` replaces the setting (0 < minutes <= 240).
    @discardableResult
    public func startFocus(taskID: String? = nil, mode: TBDFlowFocusMode = .focus, minutes: Double? = nil) throws -> TBDFlowFocus {
        try mutate { state, now in
            var length = minutes ?? Double(mode == .focus ? state.settings.focusMinutes : state.settings.breakMinutes)
            if !(length > 0 && length <= 240) { throw TBDFlowError.invalid("Minutes must be >0 and <=240") }
            var task: TBDFlowTask?
            if let taskID {
                task = state.tasks.first { $0.id == taskID }
                if task == nil { throw TBDFlowError.notFound("Task") }
            }
            if let existing = state.focus, existing.isActive { throw TBDFlowError.timerBusy }
            if mode == .focus, let end = task?.endAt {
                length = min(length, end.timeIntervalSince(now) / 60)
            }
            if length <= 0 { throw TBDFlowError.timeboxEnded }
            let seconds = max(1, Int((length * 60).rounded()))
            let focus = TBDFlowFocus(id: makeID(), taskID: taskID, mode: mode, status: .running, startedAt: now,
                                     durationSeconds: seconds, endsAt: now.addingTimeInterval(Double(seconds)))
            state.focus = focus
            return focus
        }
    }

    @discardableResult
    public func pauseFocus() throws -> TBDFlowFocus {
        try mutate { state, now in
            guard var f = state.focus else { throw TBDFlowError.noTimer }
            guard f.status == .running else { throw TBDFlowError.invalidTimerTransition }
            f.remainingSeconds = max(0, (f.endsAt ?? now).timeIntervalSince(now))
            f.endsAt = nil
            f.status = .paused
            state.focus = f
            return f
        }
    }

    @discardableResult
    public func resumeFocus() throws -> TBDFlowFocus {
        try mutate { state, now in
            guard var f = state.focus else { throw TBDFlowError.noTimer }
            guard f.status == .paused else { throw TBDFlowError.invalidTimerTransition }
            f.endsAt = now.addingTimeInterval(f.remainingSeconds ?? 0)
            f.remainingSeconds = nil
            f.status = .running
            state.focus = f
            return f
        }
    }

    @discardableResult
    public func stopFocus() throws -> TBDFlowFocus {
        try mutate { state, _ in
            guard var f = state.focus else { throw TBDFlowError.noTimer }
            f.status = .stopped
            f.endsAt = nil
            f.remainingSeconds = nil
            state.focus = f
            return f
        }
    }

    // MARK: Reminders

    public func acknowledgeReminder(id: String) throws {
        try mutate { state, now in
            guard let i = state.reminders.firstIndex(where: { $0.id == id }) else { throw TBDFlowError.notFound("Reminder") }
            if state.reminders[i].acknowledgedAt == nil { state.reminders[i].acknowledgedAt = now }
        }
    }

    /// Hides a reminder for 1...1440 minutes. It comes back after that unless it was acknowledged.
    public func snoozeReminder(id: String, minutes: Int = 5) throws {
        guard (1...1440).contains(minutes) else { throw TBDFlowError.invalidSnooze }
        try mutate { state, now in
            guard let i = state.reminders.firstIndex(where: { $0.id == id }) else { throw TBDFlowError.notFound("Reminder") }
            state.reminders[i].snoozedUntil = now.addingTimeInterval(Double(minutes) * 60)
        }
    }

    /// v1 selection (`CompanionPlanner.refresh`): among the pending reminders (not acknowledged, not snoozed) that were
    /// last shown at least `repeatSeconds` ago, the one shown least recently. A new reminder is never starved by an old one.
    public func reminderToShow(now: Date) -> TBDFlowReminder? {
        locked {
            let repeatAfter = Double(current.settings.repeatSeconds)
            return current.reminders
                .filter { $0.isPending(at: now) && now.timeIntervalSince($0.lastShownAt ?? .distantPast) >= repeatAfter }
                .enumerated()
                .min { a, b in
                    let la = a.element.lastShownAt ?? .distantPast, lb = b.element.lastShownAt ?? .distantPast
                    return la != lb ? la < lb : a.offset < b.offset
                }?.element
        }
    }

    /// Reminders that are pending at `now` (for a list in the UI), oldest first.
    public func pendingReminders(now: Date) -> [TBDFlowReminder] {
        locked { current.reminders.filter { $0.isPending(at: now) } }
    }

    /// The app calls this after it showed (toast and sound) the reminder from `reminderToShow`.
    public func markShown(id: String, at when: Date? = nil) throws {
        try mutate { state, now in
            guard let i = state.reminders.firstIndex(where: { $0.id == id }) else { throw TBDFlowError.notFound("Reminder") }
            state.reminders[i].lastShownAt = when ?? now
        }
    }

    // MARK: Tick

    /// The scheduler step (`server.py` `tick()`, run every second there). Creates the reminders that are due (one that is more than `staleReminderAge` overdue is stored acknowledged and not returned):
    /// "Start: X" at the start (or at the end for a task with only an end), and "Timebox ended: X — finish or replan" at
    /// the end of a timebox for a task that is not done. A reminder is made once per `dedupKey`. A timebox that ended
    /// acknowledges the task's start reminder. A running timer past its end becomes `finished`. Old acknowledged reminders
    /// of finished or deleted tasks are dropped after `reminderRetention`. A tick that changes nothing writes nothing.
    @discardableResult
    public func tick(now: Date? = nil) throws -> TBDFlowTickResult {
        try mutate(now: now) { state, now in
            var created: [TBDFlowReminder] = []
            func add(_ kind: TBDFlowReminderKind, _ task: TBDFlowTask, at when: Date, title: String) {
                let key = TBDFlowReminder.dedupKey(kind: kind, taskID: task.id, at: when)
                guard !state.reminders.contains(where: { $0.dedupKey == key }) else { return }
                var r = TBDFlowReminder(id: makeID(), kind: kind, taskID: task.id, title: title, createdAt: now, dedupKey: key)
                if now.timeIntervalSince(when) > Self.staleReminderAge {
                    // Long overdue when first seen: remembered for dedup, never shown.
                    r.acknowledgedAt = now
                    state.reminders.append(r)
                    return
                }
                state.reminders.append(r)
                created.append(r)
            }
            for task in state.tasks where task.status == .todo || task.status == .doing {
                if let when = task.startAt ?? task.endAt, when <= now {
                    let timeboxOver = task.startAt != nil && (task.endAt.map { $0 <= now } ?? false)
                    if !timeboxOver { add(.start, task, at: when, title: "Start: " + task.title) }
                }
                if task.startAt != nil, let end = task.endAt, end <= now {
                    // End of the budget, not completion: the end reminder supersedes the start reminder.
                    for i in state.reminders.indices
                    where state.reminders[i].taskID == task.id && state.reminders[i].kind == .start && state.reminders[i].acknowledgedAt == nil {
                        state.reminders[i].acknowledgedAt = now
                    }
                    add(.timeboxEnded, task, at: end, title: "Timebox ended: " + task.title + " — finish or replan")
                }
            }
            var finished: TBDFlowFocus?
            if var f = state.focus, f.status == .running, let end = f.endsAt, end <= now {
                f.status = .finished
                f.finishedAt = now
                state.focus = f
                finished = f
            }
            let live = Dictionary(state.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
            state.reminders.removeAll { r in
                guard let ack = r.acknowledgedAt, now.timeIntervalSince(ack) > Self.reminderRetention else { return false }
                guard let status = live[r.taskID] else { return true }
                return status == .done || status == .cancelled
            }
            return TBDFlowTickResult(newReminders: created, finishedFocus: finished)
        }
    }

    // MARK: Card labels

    /// Stores a label for a Companion card. Returns false and changes nothing when a label of a higher author is there:
    /// a `.person` label is never overwritten by `.model` or `.rule`, and a `.model` label not by `.rule`. The same
    /// author, or a higher one, replaces it. `.onPlan` needs a task id; the others drop it.
    @discardableResult
    public func setCardLabel(cardID: String, label: TBDFlowLabel, taskID: String? = nil, by: TBDFlowLabelAuthor, at: Date? = nil,
                             cardStart: Date? = nil, cardEnd: Date? = nil) throws -> Bool {
        if label == .onPlan && taskID == nil { throw TBDFlowError.invalid("An on-plan label needs a task") }
        return try mutate { state, now in
            if let existing = state.cardLabels[cardID], existing.by.precedence > by.precedence { return false }
            state.cardLabels[cardID] = TBDFlowCardLabel(cardID: cardID, label: label, taskID: label == .onPlan ? taskID : nil, by: by,
                                                        at: at ?? now, start: cardStart, end: cardEnd)
            return true
        }
    }

    /// A label whose card id is gone (Companion rebuilt the card) moves to the card of `cards` that covers at least half of
    /// the longer of the two time spans. A person's label moves first, then the model's, then a rule's; a label already on
    /// the new card stays when it is of the same or a higher author, and then the old label is dropped. A label without a
    /// stored span, or without a matching card, stays where it is. Returns how many labels moved.
    @discardableResult
    public func reattachCardLabels(to cards: [TBDFlowCardEvidence]) throws -> Int {
        try mutate { state, _ in
            let ids = Set(cards.map(\.id))
            let orphans = state.cardLabels.values
                .filter { !ids.contains($0.cardID) && $0.start != nil && $0.end != nil }
                .sorted { a, b in
                    a.by.precedence != b.by.precedence ? a.by.precedence > b.by.precedence : (a.at != b.at ? a.at > b.at : a.cardID < b.cardID)
                }
            var moved = 0
            for label in orphans {
                guard let start = label.start, let end = label.end, end > start else { continue }
                let best = cards.compactMap { card -> (card: TBDFlowCardEvidence, share: Double)? in
                    let length = max(end.timeIntervalSince(start), card.end.timeIntervalSince(card.start))
                    guard length > 0 else { return nil }
                    let overlap = min(end, card.end).timeIntervalSince(max(start, card.start))
                    let share = overlap / length
                    return share >= TBDFlowMatcher.timeboxOverlapFraction ? (card, share) : nil
                }.max { a, b in a.share != b.share ? a.share < b.share : a.card.start > b.card.start }
                guard let target = best?.card else { continue }
                state.cardLabels[label.cardID] = nil
                if let existing = state.cardLabels[target.id], existing.by.precedence >= label.by.precedence { continue }
                var attached = label
                attached.cardID = target.id
                attached.start = target.start
                attached.end = target.end
                state.cardLabels[target.id] = attached
                moved += 1
            }
            return moved
        }
    }

    /// The person removes a correction (the card goes back to the model or rule label).
    public func clearCardLabel(cardID: String) throws {
        try mutate { state, _ in state.cardLabels[cardID] = nil }
    }

    public var cardLabels: [String: TBDFlowCardLabel] { locked { current.cardLabels } }

    // MARK: Tasklist import

    /// Adds tasks read from Tasklist; ids already in the list are skipped. Marks the import as done.
    func addImported(_ tasks: [TBDFlowTask], importedAt: Date) throws -> (added: Int, skipped: Int) {
        try mutate { state, _ in
            var added = 0
            var skipped = 0
            var seen = Set(state.tasks.map(\.id))
            for t in tasks {
                if seen.contains(t.id) { skipped += 1; continue }
                try t.validate()
                state.tasks.append(t)
                seen.insert(t.id)
                added += 1
            }
            state.tasklistImportedAt = importedAt
            return (added, skipped)
        }
    }
}
