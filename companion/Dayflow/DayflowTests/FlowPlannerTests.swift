import Combine
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
    // The task started half an hour ago: its start reminder is long overdue, so it is stored answered and shows no toast.
    planner.tick()
    XCTAssertTrue(planner.reminders.isEmpty)
    XCTAssertNotEqual(mirror.overlay, .toast(message: "Start: Write report"))

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

  // MARK: A plan pasted late in the day makes no toasts (review 4)

  func testPastingAMorningPlanAt1400MakesNoToastAndNoReminder() throws {
    clock.set("2026-10-05T14:00:00Z")
    var pings = 0
    let planner = makePlanner(sound: { pings += 1 })
    let text = "08:00-09:00 Plan the day\n09:00-10:00 Write report\n10:00-11:00 Call Anna\n11:00-12:00 Review"
    let zone = TimeZone(identifier: "UTC")!
    let preview = try planner.previewPlan(text: text, day: day, timeZone: zone)
    _ = try planner.commitPlan(preview, text: text, day: day, idempotencyKey: "late", timeZone: zone)
    XCTAssertEqual(planner.tasks.count, 4)
    planner.tick()
    XCTAssertEqual(planner.reminders, [], "all four are long overdue: stored answered, never shown")
    XCTAssertEqual(pings, 0)
    XCTAssertEqual(mirror.overlay, .hidden, "no toast")
    clock.advance(120)
    planner.tick()
    XCTAssertEqual(pings, 0)
    XCTAssertEqual(mirror.overlay, .hidden)
  }

  // MARK: One "Break's over" toast (review 5)

  func testABreakTimerThatEndsInsideASessionMakesOneBreaksOverToast() throws {
    let store = makeStore()
    try add(store, "Write report", "09:20:00Z", "11:00:00Z")
    let planner = makePlanner(store: store)
    planner.tick()
    planner.acknowledge(try XCTUnwrap(planner.reminders.first))
    planner.startBreak()
    XCTAssertEqual(mirror.snapshot.phase, .onBreak)
    mirror.debugHideOverlay()  // the tub went away
    var shown: [String] = []
    let watch = mirror.$overlay.dropFirst().sink { if case .toast(let message) = $0 { shown.append(message) } }
    defer { watch.cancel() }
    clock.advance(5 * 60 + 1)
    planner.tick()
    XCTAssertEqual(shown, ["Break's over. Back to it!"], "one toast, not two")
    XCTAssertEqual(mirror.queuedToastMessages, [])
  }

  func testAGoalAddedDuringABreakDoesNotShowTheTubAgain() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "11:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()
    planner.startBreak()
    XCTAssertEqual(mirror.overlay, .onBreak)
    mirror.debugHideOverlay()
    try planner.addTask(title: "Call Anna", notes: "", day: day, startAt: at("09:00:00Z"), endAt: at("10:00:00Z"))
    XCTAssertEqual(mirror.snapshot.goals.count, 2, "the goal arrived")
    XCTAssertEqual(mirror.overlay, .hidden, "the tub does not come back")
    XCTAssertEqual(observer.events.filter { $0 == "pause" }.count, 1)
  }

  // MARK: A new plan after an ended session is a new session (review 10)

  func testANewPlanAfterTheSessionEndedGetsAFreshStart() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, Int(at("09:30:00Z").timeIntervalSince1970))

    clock.set("2026-10-05T10:00:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .ended, "no plan left: the bubble stays")

    clock.set("2026-10-05T10:05:00Z")
    try add(store, "Second round", "10:05:00Z", "11:00:00Z")
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, Int(at("10:05:00Z").timeIntervalSince1970), "fresh start, not 09:30")
    XCTAssertEqual(observer.events.suffix(2), ["stop", "start"])
    XCTAssertTrue(planner.ownedSession)
  }

  // MARK: The person wins over the observer (review 15)

  func testALocalTaskThePersonReopenedIsNotClosedAgainInThatSession() throws {
    let store = makeStore()
    let task = try add(store, "Write report", "09:00:00Z", "11:00:00Z")
    let planner = makePlanner(store: store)
    planner.start()
    defer { planner.stop() }
    XCTAssertEqual(mirror.snapshot.phase, .active)
    mirror.agentCompletedGoals([TBDFlowGoal(id: task.id, title: "Write report")])
    XCTAssertEqual(planner.tasks.first?.status, .done, "the observer closed it")

    clock.advance(60)
    planner.toggleDone(try XCTUnwrap(planner.tasks.first))  // the person reopens it
    XCTAssertEqual(planner.tasks.first?.status, .todo)
    mirror.debugHideOverlay()
    // The observer reports it again (a restart forgot what it reported).
    mirror.agentCompletedGoals([TBDFlowGoal(id: task.id, title: "Write report")])
    XCTAssertEqual(planner.tasks.first?.status, .todo, "the person's choice stands")
    XCTAssertEqual(mirror.overlay, .hidden, "and no Checked off toast")
    planner.detectedCompletion(taskID: task.id)
    XCTAssertEqual(planner.tasks.first?.status, .todo)

    // A task nobody reopened is still closed by the observer.
    let other = try add(store, "Call Anna", "09:00:00Z", "11:00:00Z")
    planner.refresh()
    planner.detectedCompletion(taskID: other.id)
    XCTAssertEqual(planner.tasks.first { $0.id == other.id }?.status, .done)
  }

  func testAReopenedTaskCanBeClosedByTheObserverInALaterSession() throws {
    let store = makeStore()
    let task = try add(store, "Write report", "09:00:00Z", "10:00:00Z")
    let planner = makePlanner(store: store)
    planner.refresh()
    planner.detectedCompletion(taskID: task.id)
    planner.toggleDone(try XCTUnwrap(planner.tasks.first))
    XCTAssertNotNil(planner.tasks.first?.reopenedAt)

    clock.set("2026-10-05T10:00:01Z")
    mirror.handleDeadline()
    clock.set("2026-10-05T10:10:00Z")
    try add(store, "Second round", "10:10:00Z", "11:00:00Z")
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.sessionStartedAt, Int(at("10:10:00Z").timeIntervalSince1970))
    planner.detectedCompletion(taskID: task.id)
    XCTAssertEqual(planner.tasks.first { $0.id == task.id }?.status, .done, "a new session: the old reopen no longer counts")
  }

  // MARK: Relaunch during a break (review 14)

  func testRelaunchDuringABreakAdoptsTheSessionWithoutAFalseBreaksOverToast() throws {
    let store = makeStore()
    try add(store, "Write report", "09:00:00Z", "11:00:00Z")
    try add(store, "Short break", "09:20:00Z", "09:50:00Z")
    makePlanner(store: store).refresh()
    XCTAssertEqual(mirror.snapshot.phase, .onBreak)
    let startedAt = mirror.snapshot.sessionStartedAt
    // The app starts again: a new mirror restores the break, a new planner syncs.
    clock.advance(60)
    let relaunchedObserver = RecordingObserver()
    observer = relaunchedObserver
    let restored = FlowSessionMirror(
      defaults: defaults, settings: settings, timeline: timeline, observer: relaunchedObserver, now: { [clock] in clock.now })
    XCTAssertEqual(restored.snapshot.phase, .onBreak)
    let planner = FlowPlanner(
      store: store, mirror: restored, defaults: defaults, calendar: Self.utc, now: { [clock] in clock.now }, playSound: {},
      taskBoard: FlowTaskBoardSource(client: FakeTaskBoardClient()), cardsForDay: { _ in [] })
    planner.refresh()
    XCTAssertEqual(restored.snapshot.phase, .onBreak)
    XCTAssertEqual(restored.snapshot.sessionStartedAt, startedAt, "the session keeps its start")
    XCTAssertEqual(relaunchedObserver.events, ["start(rebrief)"], "handed over once; no resume, no second pause")
    XCTAssertNotEqual(restored.overlay, .toast(message: "Break's over. Back to it!"))
  }

  // MARK: An unreadable list says so (review 19)

  func testACorruptListFileMakesANoticeWithTheNameOfTheKeptCopy() throws {
    let url = folder.appendingPathComponent("Companion/flow.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{ not json".utf8).write(to: url)
    let planner = makePlanner(store: makeStore())
    let name = try XCTUnwrap(planner.store.corruptBackupURL?.lastPathComponent)
    XCTAssertTrue(name.hasPrefix("flow.json.corrupt-"))
    XCTAssertEqual(planner.storeNotice, "TBD could not read your Flow list. It kept a copy at \(name). Your list starts empty.")
    XCTAssertTrue(planner.tasks.isEmpty)
  }

  func testNoNoticeForAHealthyOrMissingFile() throws {
    XCTAssertNil(makePlanner().storeNotice)
  }

  func testWhenTheFileCannotBeMovedAsideTheNoticeSaysNothingIsSaved() throws {
    let url = folder.appendingPathComponent("Companion/flow.json")
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let junk = Data("{ not json".utf8)
    try junk.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
    let planner = makePlanner(store: makeStore())
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    let text = try XCTUnwrap(planner.storeNotice)
    XCTAssertTrue(text.contains("could not move the file aside"))
    XCTAssertThrowsError(try planner.addTask(title: "Fresh", notes: "", day: day, startAt: nil, endAt: nil))
    XCTAssertEqual(try Data(contentsOf: url), junk, "the unreadable file is not overwritten")
  }
}
