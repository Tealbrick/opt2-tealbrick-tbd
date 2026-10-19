import XCTest
import TBDModels

@testable import TBD

/// `FlowPlanner`: the local list becomes the mirror's session exactly as v1 `syncObservation` did, reminders and
/// finished timers become toasts, and the page actions change the store.
@MainActor
final class FlowPlannerTests: FlowTestCase {
  private let day = "2026-10-05"

  @discardableResult
  private func add(_ store: TBDFlowStore, _ title: String, _ start: String, _ end: String, notes: String = "", subtasks: [String] = []) throws
    -> TBDFlowTask
  {
    try store.addTask(title: title, notes: notes, subtasks: subtasks, day: day, startAt: at(start), endAt: at(end))
  }

  func testNoTasksMeansIdle() {
    let planner = makePlanner()
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertFalse(planner.ownedSession)
    XCTAssertEqual(observer.events, [])
  }

  func testActiveSessionWithGoals() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z", notes: "Draft only", subtasks: ["outline", "intro"])
    try add(store, "Later", "11:00:00Z", "12:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()

    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.snapshot.alertStyle, .friendly)
    XCTAssertEqual(mirror.snapshot.goals.map(\.title), ["Write report — Required steps: outline; intro — Draft only"])
    XCTAssertEqual(mirror.snapshot.sessionEndsAt, Int(at("12:00:00Z").timeIntervalSince1970), "the latest end of today")
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, Int(clock.now.timeIntervalSince1970))
    XCTAssertTrue(planner.ownedSession)
    XCTAssertEqual(observer.events, ["start"])

    // A later refresh keeps the start and changes nothing.
    clock.advance(30)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, Int(at("09:30:00Z").timeIntervalSince1970))
    XCTAssertEqual(observer.events, ["start"])

    // Ticking the goal off ends the session when no other goal has started.
    planner.toggleDone(try XCTUnwrap(planner.tasks.first { $0.title == "Write report" }))
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertEqual(observer.events.last, "stop")
    XCTAssertFalse(planner.ownedSession)
  }

  func testABreakByTitlePausesAndEndsByTheClock() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    try add(store, "Short break", "09:20:00Z", "09:40:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()

    XCTAssertEqual(mirror.snapshot.phase, .onBreak)
    XCTAssertEqual(mirror.snapshot.breakEndsAt, Int(at("09:40:00Z").timeIntervalSince1970))
    XCTAssertEqual(mirror.snapshot.goals.map(\.title), ["Write report"], "the break is not a goal")
    // The session starts as active once so the observer owns a live conversation, then the break pauses it.
    XCTAssertEqual(observer.events, ["start", "pause"])
    XCTAssertEqual(mirror.overlay, .onBreak)

    clock.set("2026-10-05T09:41:00Z")
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(observer.events.suffix(2), ["resume", "goals"])
  }

  func testTheBreakTimerIsABreakToo() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .active)

    planner.startBreak()
    XCTAssertEqual(mirror.snapshot.phase, .onBreak)
    XCTAssertEqual(mirror.snapshot.breakEndsAt, Int(clock.now.addingTimeInterval(5 * 60).timeIntervalSince1970))

    planner.stopFocus()
    XCTAssertEqual(mirror.snapshot.phase, .active)
  }

  func testSwitchingTheObserverOffEndsTheSession() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .active)

    defaults.set(false, forKey: FlowPlanner.observationKey)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertFalse(planner.ownedSession)

    defaults.set(true, forKey: FlowPlanner.observationKey)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .active)
  }

  func testASessionThatEndedByItselfKeepsItsBubble() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()

    clock.set("2026-10-05T10:00:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.overlay, .sessionEnded)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    XCTAssertEqual(mirror.overlay, .sessionEnded, "the planner does not wipe the bubble")
  }

  func testDetectedCompletionChecksTheTaskOff() throws {
    let store = makeStore()
    let task = try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.start()
    defer { planner.stop() }
    XCTAssertEqual(mirror.snapshot.phase, .active)

    mirror.agentCompletedGoals([TBDFlowGoal(id: task.id, title: "Write report")])
    XCTAssertEqual(planner.tasks.first?.status, .done)
    XCTAssertNotNil(planner.tasks.first?.completedAt)
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertEqual(mirror.overlay, .toast(message: "Checked off: Write report"))

    // A task that is not in the list, or already done, is ignored.
    planner.detectedCompletion(taskID: "nope")
    planner.detectedCompletion(taskID: task.id)
    XCTAssertEqual(planner.notice, nil)
  }

  func testAStartReminderBecomesAToastWithASoundAndRepeats() throws {
    let store = makeStore()
    try add(store, "Write report", "09:20:00Z", "10:00:00Z")
    var pings = 0
    let planner = makePlanner(store: store, sound: { pings += 1 })

    planner.tick()
    XCTAssertEqual(planner.reminders.map(\.title), ["Start: Write report"])
    XCTAssertEqual(pings, 1)
    XCTAssertTrue({
      if case .toast(let m) = mirror.overlay { return m == "Start: Write report" }
      return false
    }())

    // Not again before the repeat interval (60 s); then again, until it is acknowledged.
    clock.advance(30)
    planner.tick()
    XCTAssertEqual(pings, 1)
    clock.advance(31)
    planner.tick()
    XCTAssertEqual(pings, 2)

    planner.acknowledge(try XCTUnwrap(planner.reminders.first))
    XCTAssertEqual(planner.reminders, [])
    clock.advance(120)
    planner.tick()
    XCTAssertEqual(pings, 2)
  }

  func testSoundAndOverlaySettingsAreRespected() throws {
    let store = makeStore()
    try add(store, "Write report", "09:20:00Z", "10:00:00Z")
    try store.updateSettings { $0.sound = false; $0.overlay = false }
    var pings = 0
    let planner = makePlanner(store: store, sound: { pings += 1 })
    planner.tick()
    XCTAssertEqual(pings, 0)
    if case .toast(let m) = mirror.overlay, m.hasPrefix("Start:") { XCTFail("overlay is off") }
    XCTAssertEqual(planner.reminders.count, 1, "the reminder waits on the page")
  }

  func testAFinishedTimerBecomesAToast() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "11:00:00Z")
    let planner = makePlanner(store: store)
    planner.startFocus(try XCTUnwrap(store.state.tasks.first))
    XCTAssertEqual(planner.focus?.mode, .focus)
    XCTAssertEqual(planner.focus?.durationSeconds, 25 * 60)
    // The task already started, so its start reminder is waiting: answer it, or its toast would cover the timer's.
    planner.tick()
    planner.acknowledge(try XCTUnwrap(planner.reminders.first))

    clock.advance(25 * 60 + 1)
    planner.tick()
    XCTAssertEqual(planner.focus?.status, .finished)
    XCTAssertEqual(mirror.overlay, .toast(message: "Focus done. Take a short break?"))

  }

  func testAFinishedBreakWithoutASessionSaysSo() throws {
    let planner = makePlanner()
    planner.startBreak()
    XCTAssertEqual(planner.focus?.mode, .break)
    clock.advance(5 * 60 + 1)
    planner.tick()
    XCTAssertEqual(mirror.overlay, .toast(message: "Break's over."))
  }

  func testStartFocusOnAnEndedTimeboxSaysWhy() throws {
    let store = makeStore()
    let task = try add(store, "Old", "08:00:00Z", "09:00:00Z")
    let planner = makePlanner(store: store)
    planner.startFocus(task)
    XCTAssertEqual(planner.notice, "This timebox has ended. Replan it before starting focus.")
    XCTAssertNil(planner.focus)
  }

  func testPastePreviewCommitIsIdempotent() throws {
    let planner = makePlanner()
    let text = "09:00-09:30 Plan the day\nTODO Answer mail"
    let preview = try planner.previewPlan(text: text, day: day, timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertEqual(preview.engine, .strict)
    XCTAssertEqual(preview.drafts.map(\.title), ["Plan the day", "Answer mail"])

    let first = try planner.commitPlan(preview, text: text, day: day, idempotencyKey: "k1", timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertEqual(first.taskIDs.count, 2)
    XCTAssertEqual(planner.tasks.count, 2)
    let again = try planner.commitPlan(preview, text: text, day: day, idempotencyKey: "k1", timeZone: TimeZone(identifier: "UTC")!)
    XCTAssertTrue(again.replayed)
    XCTAssertEqual(planner.tasks.count, 2)
    // The same key for another text is refused.
    XCTAssertThrowsError(
      try planner.commitPlan(preview, text: text + "\nTODO more", day: day, idempotencyKey: "k1", timeZone: TimeZone(identifier: "UTC")!))
  }

  func testAddTaskValidatesAndShowsInThePlan() throws {
    let planner = makePlanner()
    XCTAssertThrowsError(try planner.addTask(title: "  ", notes: "", day: day, startAt: nil, endAt: nil))
    XCTAssertThrowsError(try planner.addTask(title: "x", notes: "", day: day, startAt: at("10:00:00Z"), endAt: at("09:00:00Z")))
    let task = try planner.addTask(title: "Read", notes: "chapter 3", day: day, startAt: nil, endAt: nil)
    XCTAssertEqual(planner.tasks.map(\.id), [task.id])
    XCTAssertEqual(planner.todayKey, day)
  }

  func testTheTickDoesNotWriteWhenNothingChanged() throws {
    let store = makeStore()
    try add(store, "Write report", "11:00:00Z", "12:00:00Z")
    let planner = makePlanner(store: store)
    let before = try Data(contentsOf: store.url)
    planner.tick()
    planner.tick()
    XCTAssertEqual(try Data(contentsOf: store.url), before)
  }
}
