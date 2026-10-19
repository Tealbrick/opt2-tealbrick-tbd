//
//  FlowPlanner.swift
//  TBD
//
//  The Flow list on this Mac (replaces v1 `CompanionPlanner`, which talked to the Tasklist service). It owns a
//  `TBDFlowStore`, ticks it once a second, publishes the list for the Flow page, shows reminders and finished timers
//  as creature toasts, and turns today's tasks into the session the overlay and the observer follow. No network.
//

import AppKit
import Foundation
import TBDModels

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

  private let mirror: FlowSessionMirror
  private let defaults: UserDefaults
  private let calendar: Calendar
  private let now: () -> Date
  private let playSound: () -> Void
  private var timer: Timer?
  /// True while this planner owns the mirror's session (it started it, so it must end it).
  private(set) var ownedSession = false

  init(
    store: TBDFlowStore? = nil, mirror: FlowSessionMirror? = nil, defaults: UserDefaults = .standard,
    calendar: Calendar = .current, now: @escaping () -> Date = { Date() },
    playSound: @escaping () -> Void = { NSSound(named: "Ping")?.play() }
  ) {
    self.store = store ?? TBDFlowStore()
    self.mirror = mirror ?? .shared
    self.defaults = defaults
    self.calendar = calendar
    self.now = now
    self.playSound = playSound
    self.clock = now()
    load()
  }

  // MARK: - Clock

  /// Starts the one-second clock. Called once from the AppDelegate (never in the XCTest host).
  func start() {
    guard timer == nil else { return }
    mirror.onGoalsCompleted = { [weak self] goals in
      for goal in goals { self?.detectedCompletion(taskID: goal.id) }
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
  func detectedCompletion(taskID: String) {
    guard let task = tasks.first(where: { $0.id == taskID }), task.status != .done, task.status != .cancelled else { return }
    run { try store.setStatus(id: taskID, .done) }
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

  func toggleDone(_ task: TBDFlowTask) {
    run { try store.setStatus(id: task.id, task.status == .done ? .todo : .done) }
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
