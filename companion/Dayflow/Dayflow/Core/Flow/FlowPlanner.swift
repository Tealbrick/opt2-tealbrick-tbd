//
//  FlowPlanner.swift
//  TBD
//
//  The Flow list on this Mac (replaces v1 `CompanionPlanner`, which talked to the Tasklist service). It owns a
//  `TBDFlowStore`, ticks it once a second, publishes the list for the Flow page, shows reminders and finished timers
//  as creature toasts, and turns today's tasks into the session the overlay and the observer follow. No network.
//

import AppKit
import Combine
import Foundation
import TBDModels

/// What a Task Board task row shows while a "Mark done on Task Board" tap is running (F4).
enum FlowTaskBoardRowState: Equatable {
  /// The call is on its way.
  case working
  /// The owner has to approve first ("Waiting for owner approval").
  case waiting(String)
  /// The call failed: the sentence shown on the row. The task stays open.
  case failed(String)
}

@MainActor
final class FlowPlanner: ObservableObject {
  static let shared = FlowPlanner()

  /// UserDefaults key of the session switch (default on): whether the list becomes a session at all. The observer's own
  /// switch ("Watch my screen for focus", off until turned on) is `TBDFlowObserverSetup.watching`.
  static let observationKey = "companionObservationEnabled"

  let store: TBDFlowStore

  @Published private(set) var tasks: [TBDFlowTask] = []
  @Published private(set) var focus: TBDFlowFocus?
  /// Reminders that are waiting for "Done" or "Snooze" (not acknowledged, not snoozed).
  @Published private(set) var reminders: [TBDFlowReminder] = []
  @Published private(set) var settings = TBDFlowSettings()
  /// The planner's clock; it moves once a second so the page shows the timer and "Now" without its own timers.
  @Published private(set) var clock: Date
  /// The last thing that went wrong, in the words the page shows (v1 `connection`). Cleared by the next action.
  @Published var notice: String?
  /// Task id → what its "Mark done on Task Board" tap is doing (F4). Absent = nothing running.
  @Published private(set) var taskBoardRows: [String: FlowTaskBoardRowState] = [:]

  /// Where the list comes from (F4): Task Board when licensed, connected and granted, else this Mac.
  let taskBoard: FlowTaskBoardSource

  private let mirror: FlowSessionMirror
  private let defaults: UserDefaults
  private let calendar: Calendar
  private let now: () -> Date
  private let playSound: () -> Void
  private let cardsForDay: (String) -> [TimelineCard]
  private var forwarding: AnyCancellable?
  private var timer: Timer?
  /// True while this planner owns the mirror's session (it started it, so it must end it).
  private(set) var ownedSession = false

  init(
    store: TBDFlowStore? = nil, mirror: FlowSessionMirror? = nil, defaults: UserDefaults = .standard,
    calendar: Calendar = .current, now: @escaping () -> Date = { Date() },
    playSound: @escaping () -> Void = { NSSound(named: "Ping")?.play() },
    taskBoard: FlowTaskBoardSource? = nil,
    cardsForDay: @escaping (String) -> [TimelineCard] = { StorageManager.shared.fetchTimelineCards(forDay: $0) }
  ) {
    self.store = store ?? TBDFlowStore()
    self.mirror = mirror ?? .shared
    self.defaults = defaults
    self.calendar = calendar
    self.now = now
    self.playSound = playSound
    self.taskBoard = taskBoard ?? .shared
    self.cardsForDay = cardsForDay
    self.clock = now()
    // The page watches the planner only: a changed source or issue list redraws it.
    forwarding = self.taskBoard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    load()
  }

  // MARK: - Clock

  /// Starts the one-second clock. Called once from the AppDelegate (never in the XCTest host).
  func start() {
    guard timer == nil else { return }
    mirror.onGoalsCompleted = { [weak self] goals in
      for goal in goals { self?.detectedCompletion(taskID: goal.id) }
    }
    // Only tasks that were really checked off get the "Checked off" toast; a Task Board task gets "Looks done" instead.
    mirror.goalsToAnnounce = { [weak self] goals in
      guard let self else { return goals }
      return goals.filter { goal in self.tasks.first(where: { $0.id == goal.id })?.source != .taskBoard }
    }
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// One scheduler step: new reminders and a finished timer, then the published state, the reminder toast and the session.
  func tick() {
    do {
      let result = try store.tick(now: now())
      if let finished = result.finishedFocus { showFinished(finished) }
    } catch {
      notice = error.localizedDescription
    }
    refresh()
    showReminderIfDue()
  }

  /// Reads the store, publishes it, and applies the session to the mirror.
  func refresh() {
    load()
    syncObservation()
  }

  /// Reads the store and publishes it, without touching the mirror (design shots and previews use this).
  func load() {
    let state = store.state
    let current = now()
    if tasks != state.tasks { tasks = state.tasks }
    if focus != state.focus { focus = state.focus }
    if settings != state.settings { settings = state.settings }
    let pending = store.pendingReminders(now: current)
    if reminders != pending { reminders = pending }
    clock = current
  }

  // MARK: - Toasts

  private func showFinished(_ finished: TBDFlowFocus) {
    guard settings.overlay else { return }
    mirror.toast(
      finished.mode == .focus
        ? String(localized: "Focus done. Take a short break?") : String(localized: "Break's over."))
  }

  /// v1: among the pending reminders the one shown least recently, if it is due again, becomes a toast (and a sound).
  private func showReminderIfDue() {
    let current = now()
    guard let reminder = store.reminderToShow(now: current) else { return }
    if settings.overlay { mirror.toast(reminder.title) }
    if settings.sound { playSound() }
    try? store.markShown(id: reminder.id, at: current)
  }

  // MARK: - Session

  var observationEnabled: Bool { defaults.object(forKey: Self.observationKey) as? Bool ?? true }

  /// v1 `syncObservation`: derives the session from today's tasks and the timer and applies it to the mirror. The
  /// session starts as `active` once, so the observer owns a live conversation before a break pauses it.
  func syncObservation() {
    guard observationEnabled else {
      endOwnedSession()
      return
    }
    let current = now()
    let previousStart = ownedSession ? mirror.snapshot.sessionStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
    guard
      let plan = TBDFlowSession.plan(
        tasks: tasks, focus: focus, now: current, calendar: calendar, previousStartsAt: previousStart)
    else {
      endOwnedSession()
      return
    }
    var snapshot = FlowNativeSnapshot()
    snapshot.phase = .active
    snapshot.alertStyle = FlowAgentSettings.savedAlertStyle(defaults)
    snapshot.sessionStartedAt = Int(plan.startsAt.timeIntervalSince1970)
    snapshot.sessionEndsAt = Int(plan.endsAt.timeIntervalSince1970)
    snapshot.goals = plan.goals
    if !ownedSession {
      mirror.apply(snapshot)
      ownedSession = true
    }
    if let until = plan.onBreakUntil {
      snapshot.phase = .onBreak
      snapshot.breakEndsAt = Int(until.timeIntervalSince1970)
    }
    if snapshot != mirror.snapshot { mirror.apply(snapshot) }
  }

  /// The list has no session any more: tell the mirror, except when the session just ended by itself. Then the
  /// mirror shows its "Time's up" bubble and keeps it until the person answers.
  private func endOwnedSession() {
    guard ownedSession else { return }
    if mirror.snapshot.phase == .ended { return }
    mirror.apply(.idle)
    ownedSession = false
  }

  /// The observer saw `taskID` finished on screen: tick it off. The creature's "Checked off: <title>" toast comes from
  /// the mirror (v1), which respects quiet mode.
  ///
  /// F4: a Task Board task is NOT written. Its row gets "Looks done" with "Mark done on Task Board" / "Not yet"; only the
  /// person's tap writes (`completeOnTaskBoard`). "Not yet" keeps the hint away for 30 minutes.
  func detectedCompletion(taskID: String) {
    guard let task = tasks.first(where: { $0.id == taskID }), task.status != .done, task.status != .cancelled else { return }
    guard task.source == .taskBoard else {
      run { try store.setStatus(id: taskID, .done) }
      return
    }
    let isNew = (try? store.markLooksDone(id: taskID, at: now())) ?? false
    refresh()
    if isNew, settings.overlay, FlowAgentSettings.savedAlertStyle(defaults) != .quiet {
      mirror.toast(String(localized: "Looks done: \(task.title). Mark it done on Task Board when you are ready."))
    }
  }

  // MARK: - Page actions

  /// Runs a store change, shows its error text, and refreshes. Returns true when it worked.
  @discardableResult
  private func run(_ change: () throws -> Void) -> Bool {
    notice = nil
    do {
      try change()
      refresh()
      return true
    } catch {
      notice = error.localizedDescription
      refresh()
      return false
    }
  }

  /// A Task Board task that is not done: ticking it asks first ("Mark done on Task Board?"), then writes.
  func needsTaskBoardConfirm(_ task: TBDFlowTask) -> Bool {
    task.source == .taskBoard && task.taskBoardID != nil && task.status != .done && task.status != .cancelled
  }

  func toggleDone(_ task: TBDFlowTask) {
    run { try store.setStatus(id: task.id, task.status == .done ? .todo : .done) }
  }

  // MARK: - Task Board (F4)

  /// Minutes the timeline put on this task today (effective labels: person > model > rule). 0 is allowed.
  func minutesOnPlan(for task: TBDFlowTask) -> Int {
    let current = now()
    let day = FlowCardLabeller.companionDay(current, calendar: calendar)
    let plan = tasks.filter { $0.day == task.day && $0.status != .cancelled }
    let cards = cardsForDay(day).compactMap { FlowCardLabeller.evidence(for: $0, calendar: calendar) }
    let minutes = TBDFlowMatcher.minutesPerTask(labels: store.cardLabels, cards: cards, tasks: plan)[task.id] ?? 0
    return Int(minutes.rounded())
  }

  /// The person tapped "Mark done on Task Board" (after the inline confirm). Writes ONE call through TBD's agent; on
  /// success the local task is done too. A hold shows "Waiting for owner approval" on the row; an error shows its
  /// sentence on the row and the task stays open.
  func completeOnTaskBoard(_ task: TBDFlowTask) async {
    guard needsTaskBoardConfirm(task), let issue = task.taskBoardID else { return }
    if case .working = taskBoardRows[task.id] { return }
    if case .waiting = taskBoardRows[task.id] { return }
    let id = task.id
    taskBoardRows[id] = .working
    let result = TBDFlowTaskBoardResult.text(minutesOnPlan: minutesOnPlan(for: task))
    do {
      _ = try await taskBoard.complete(issue: issue, result: result) { [weak self] message in
        self?.taskBoardRows[id] = .waiting(message)
      }
      taskBoardRows[id] = nil
      run { try store.setStatus(id: id, .done) }
    } catch {
      taskBoardRows[id] = .failed(error.localizedDescription)
    }
  }

  /// "Not yet" on a "Looks done" row.
  func dismissLooksDone(_ task: TBDFlowTask) {
    run { try store.dismissLooksDone(id: task.id) }
  }

  func clearTaskBoardRow(_ task: TBDFlowTask) { taskBoardRows[task.id] = nil }

  /// One pick of the "Add from Task Board" sheet: the issue, and the timebox the person typed (the times stay here).
  struct TaskBoardPick {
    var issue: TBDFlowTaskBoardIssue
    var startAt: Date?
    var endAt: Date?
  }

  /// Adds the picked issues to today as Task Board tasks (title snapshot, project, timebox). An issue already on today's
  /// plan is skipped. Nothing is written to Task Board. Returns how many were added.
  @discardableResult
  func addFromTaskBoard(_ picks: [TaskBoardPick]) throws -> Int {
    var added = 0
    let existing = Set(tasks.filter { $0.day == todayKey && $0.status != .cancelled }.compactMap(\.taskBoardID))
    for pick in picks where !existing.contains(pick.issue.id) {
      try store.addTask(
        title: pick.issue.title, notes: "", day: todayKey, startAt: pick.startAt, endAt: pick.endAt, source: .taskBoard,
        taskBoardID: pick.issue.id, taskBoardProject: pick.issue.project.isEmpty ? nil : pick.issue.project)
      added += 1
    }
    refresh()
    return added
  }

  /// A preview with the Task Board links applied: while Task Board is the source, a line whose title equals one open issue
  /// of the owner is linked to it. Other lines stay on this Mac. No issue is ever created.
  func linked(_ preview: TBDFlowPlanPreview) -> TBDFlowPlanPreview {
    guard taskBoard.isTaskBoard else { return preview }
    var out = preview
    out.drafts = TBDFlowTaskBoardLinker.link(preview.drafts, issues: taskBoard.issues)
    return out
  }

  /// "Start focus": up to the focus length, never past the end of the timebox (a past timebox says why it cannot).
  func startFocus(_ task: TBDFlowTask) {
    run { try store.startFocus(taskID: task.id, mode: .focus) }
  }

  /// A break of the set length. A running focus timer is stopped first (a person who asks for a break wants it now).
  func startBreak() {
    run {
      if let current = store.state.focus, current.isActive { try store.stopFocus() }
      try store.startFocus(mode: .break)
    }
  }
  func pauseFocus() { run { try store.pauseFocus() } }
  func resumeFocus() { run { try store.resumeFocus() } }
  func stopFocus() { run { try store.stopFocus() } }
  func toggleSubtask(_ task: TBDFlowTask, _ subtask: TBDFlowSubtask) {
    run { try store.toggleSubtask(taskID: task.id, subtaskID: subtask.id) }
  }
  func acknowledge(_ reminder: TBDFlowReminder) { run { try store.acknowledgeReminder(id: reminder.id) } }
  func snooze(_ reminder: TBDFlowReminder, minutes: Int = 5) { run { try store.snoozeReminder(id: reminder.id, minutes: minutes) } }

  /// Adds one task. Throws the rule that failed (the sheet shows it).
  @discardableResult
  func addTask(title: String, notes: String, day: String, startAt: Date?, endAt: Date?) throws -> TBDFlowTask {
    let task = try store.addTask(title: title, notes: notes, day: day, startAt: startAt, endAt: endAt)
    refresh()
    return task
  }

  /// The tasks a pasted plan would make (strict format first, then the lenient reading), nothing is saved yet.
  func previewPlan(text: String, day: String, timeZone: TimeZone = .current) throws -> TBDFlowPlanPreview {
    try TBDFlowPlanParser.preview(text: text, day: day, timeZone: timeZone)
  }

  /// Saves a previewed plan. The same key and text again changes nothing (a double tap is safe).
  @discardableResult
  func commitPlan(_ preview: TBDFlowPlanPreview, text: String, day: String, idempotencyKey: String, timeZone: TimeZone = .current) throws
    -> TBDFlowCommitResult
  {
    let format = preview.engine == .strict ? TBDFlowPlanParser.format : "lenient"
    let hash = TBDFlowPlanParser.payloadHash(format: format, text: text, day: day, timeZone: timeZone)
    let result = try store.commit(drafts: preview.drafts, idempotencyKey: idempotencyKey, payloadHash: hash)
    refresh()
    return result
  }

  /// Reads the Tasklist database (read-only) and adds its open tasks.
  @discardableResult
  func importFromTasklist() throws -> TBDTasklistImportResult {
    let result = try TBDTasklistImport.importOpenTasks(into: store, now: now(), calendar: calendar)
    refresh()
    return result
  }

  // MARK: - Day helpers

  /// `yyyy-MM-dd` of the planner's today.
  var todayKey: String { TBDFlowDay.string(from: clock, calendar: calendar) }
  var currentCalendar: Calendar { calendar }
}
