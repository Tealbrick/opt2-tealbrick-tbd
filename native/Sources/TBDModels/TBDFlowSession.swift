import Foundation

/// A task the observer checks the screen against (v1 `FlowGoalTask`).
public struct TBDFlowGoal: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// `Title — Required steps: a; b — notes`.
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// A Flow session as the overlay and the observer need it (v1 `FlowNativeSnapshot`, without the bridge fields).
public struct TBDFlowSessionPlan: Codable, Equatable, Sendable {
    public var startsAt: Date
    /// The latest end of any task of today.
    public var endsAt: Date
    public var goals: [TBDFlowGoal]
    /// Set while a scheduled break or the break timer runs: when it ends.
    public var onBreakUntil: Date?
    public var isOnBreak: Bool { onBreakUntil != nil }
}

/// Session rules ported from v1 `CompanionPlanner.syncObservation` (FlowView.swift) and the schedule view. Pure functions:
/// the app calls them on each store change and each clock tick.
public enum TBDFlowSession {
    /// Titles that mark a scheduled break (they are not goals, and the observer pauses).
    public static let breakTitles = ["Lunch / screen break", "Short break"]

    public static func isBreak(_ task: TBDFlowTask) -> Bool { breakTitles.contains(task.title) }

    /// The session for `now`, or nil when there is none.
    ///
    /// A session exists while today has at least one goal and the last task of today ends in the future. "Today" is the
    /// tasks that start on the calendar day of `now` and are not cancelled. Goals are today's tasks that are not done, are
    /// not break tasks and have started, ordered by start. It is on a break while a break task contains `now`, or while the
    /// break timer runs (the timer wins when both apply).
    ///
    /// - Parameter previousStartsAt: `startsAt` of the session the app already owns; kept so the start does not move on
    ///   every refresh. Without it the session starts at `now`.
    public static func plan(tasks: [TBDFlowTask], focus: TBDFlowFocus?, now: Date, calendar: Calendar,
                            previousStartsAt: Date? = nil) -> TBDFlowSessionPlan? {
        let today = tasks.filter { t in
            guard let start = t.startAt else { return false }
            return calendar.isDate(start, inSameDayAs: now) && t.status != .cancelled
        }
        let scheduledBreak = today.first { t in
            isBreak(t) && (t.startAt ?? .distantFuture) <= now && now < (t.endAt ?? .distantPast)
        }
        let timerBreak = focus?.mode == .break && focus?.status == .running
        let goals = today
            .filter { $0.status != .done && !isBreak($0) && ($0.startAt ?? .distantFuture) <= now }
            .sorted { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) }
        guard let end = today.compactMap(\.endAt).max(), end > now, !goals.isEmpty else { return nil }
        var onBreakUntil: Date?
        if timerBreak {
            onBreakUntil = focus?.endsAt ?? now
        } else if let scheduledBreak {
            onBreakUntil = scheduledBreak.endAt ?? now
        }
        return TBDFlowSessionPlan(
            startsAt: previousStartsAt ?? now, endsAt: end,
            goals: goals.map { TBDFlowGoal(id: $0.id, title: goalText($0)) }, onBreakUntil: onBreakUntil)
    }

    /// `Title — Required steps: a; b — notes`, with the parts that are empty left out.
    public static func goalText(_ task: TBDFlowTask) -> String {
        task.title
            + (task.subtasks.isEmpty ? "" : " — Required steps: " + task.subtasks.map(\.title).joined(separator: "; "))
            + (task.notes.isEmpty ? "" : " — " + task.notes)
    }

    /// Open tasks of a day (not done, not cancelled), by start time; tasks without a start come first (v1 `todayTasks`).
    public static func openTasks(_ tasks: [TBDFlowTask], day: String) -> [TBDFlowTask] {
        tasks.filter { $0.day == day && $0.status != .done && $0.status != .cancelled }
            .sorted { ($0.startAt ?? .distantPast) < ($1.startAt ?? .distantPast) }
    }

    /// The open task whose timebox contains `now` (v1 `current`).
    public static func nowTask(_ tasks: [TBDFlowTask], day: String, now: Date) -> TBDFlowTask? {
        openTasks(tasks, day: day).first { t in
            guard let start = t.startAt, let end = t.endAt else { return false }
            return start <= now && now < end
        }
    }

    /// The first open task that starts after `now` (v1 `next`).
    public static func nextTask(_ tasks: [TBDFlowTask], day: String, now: Date) -> TBDFlowTask? {
        openTasks(tasks, day: day).first { ($0.startAt ?? .distantPast) > now }
    }

    /// "Timebox ended": the task is not finished and its end has passed (v1 `expired`).
    public static func isTimeboxEnded(_ task: TBDFlowTask, now: Date) -> Bool {
        guard task.status != .done, task.status != .cancelled, let end = task.endAt else { return false }
        return end <= now
    }
}
