import XCTest
import TBDModels

@testable import TBD

/// The overlay state machine (v1 FlowSessionMirror): phases, snooze and deadline nudges, escalation.
@MainActor
final class FlowSessionMirrorTests: FlowTestCase {
  func testIdleActiveBreakActiveEnded() {
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertEqual(mirror.overlay, .hidden)

    mirror.apply(snapshot(.active))
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.overlay, .toast(message: "Your flow session starts now!"))
    XCTAssertEqual(observer.events, ["start"])

    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    XCTAssertEqual(mirror.overlay, .onBreak)
    XCTAssertEqual(mirror.overlayVariant, .side, "the tub is always the side layout")
    XCTAssertEqual(observer.events, ["start", "pause"])

    mirror.apply(snapshot(.active))
    XCTAssertEqual(mirror.overlay, .toast(message: "Break's over. Back to it!"))
    XCTAssertEqual(observer.events, ["start", "pause", "resume", "goals"])

    // A change of goals inside an active session is passed on; the same snapshot is not a new event on its own.
    mirror.apply(snapshot(.active))
    XCTAssertEqual(observer.events.last, "goals")

    // The session end passes: the mirror ends it by itself.
    clock.set("2026-10-05T10:30:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    XCTAssertEqual(mirror.overlay, .sessionEnded)
    XCTAssertEqual(observer.events.last, "stop")

    // A new session after an ended one starts again.
    mirror.apply(snapshot(.active, endsAt: "12:00:00Z"))
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertEqual(mirror.overlay, .toast(message: "Your flow session starts now!"))
    XCTAssertEqual(observer.events.suffix(2), ["stop", "start"])
  }

  func testIdleHidesTheOverlayAndStopsTheObserver() {
    mirror.apply(snapshot(.active))
    mirror.apply(.idle)
    XCTAssertEqual(mirror.overlay, .hidden)
    XCTAssertEqual(mirror.snapshot.phase, .idle)
    XCTAssertEqual(observer.events.last, "stop")
  }

  func testBreakEndsByItsOwnDeadline() {
    mirror.apply(snapshot(.active))
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    clock.set("2026-10-05T09:40:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .active)
    XCTAssertNil(mirror.snapshot.breakEndsAt)
    XCTAssertEqual(mirror.overlay, .toast(message: "Break's over. Back to it!"))
  }

  func testSnoozeThenTheDeadlineNudgesAgain() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Psst... I think you're getting distracted!", escalated: false))
    XCTAssertTrue(mirror.isDistracted)

    mirror.snooze(minutes: 5)
    XCTAssertEqual(mirror.overlay, .hidden)
    XCTAssertEqual(mirror.lastNudgeReply, .snooze)
    XCTAssertTrue(observer.notes.last?.text.contains("snoozed your nudge for 5 minutes") == true)
    XCTAssertEqual(observer.notes.last?.refocused, false)

    // The observer's own nudges are held back while the snooze runs.
    clock.advance(4 * 60)
    mirror.agentNudge(message: "Still there?")
    XCTAssertEqual(mirror.overlay, .hidden)

    // Snooze over and still distracted: the stock "snooze is up" nudge, and it is the second one in the incident.
    clock.advance(61)
    mirror.handleDeadline()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Snooze is up — ready to get back to it?", escalated: true))
  }

  func testSnoozeWithoutDistractionDoesNotNudge() {
    mirror.apply(snapshot(.active))
    mirror.snooze(minutes: 5)
    clock.advance(6 * 60)
    mirror.handleDeadline()
    XCTAssertEqual(mirror.overlay, .hidden)
  }

  func testBackToWorkClearsTheStreak() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    mirror.respondBackToWork()
    XCTAssertFalse(mirror.isDistracted)
    XCTAssertEqual(mirror.lastNudgeReply, .backToWork)
    XCTAssertEqual(mirror.overlay, .toast(message: "Nice! Keep at it"))
    XCTAssertEqual(observer.notes.last?.refocused, true)

    // The next distraction is a first nudge again, not an escalation.
    mirror.simulateDistraction()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Psst... I think you're getting distracted!", escalated: false))
  }

  func testTheSecondNudgeEscalates() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Psst... I think you're getting distracted!", escalated: false))
    mirror.simulateDistraction()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Psst... I think you're getting distracted!", escalated: true))
    mirror.agentNudge(message: "Back to the report?")
    XCTAssertEqual(mirror.overlay, .nudge(message: "Back to the report?", escalated: true))
  }

  func testCorrectingAMistakeCloses() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    mirror.correctMistake()
    XCTAssertEqual(mirror.overlay, .hidden)
    XCTAssertFalse(mirror.isDistracted)
    XCTAssertEqual(mirror.lastNudgeReply, .correct)
    XCTAssertEqual(observer.notes.last?.refocused, true)
  }

  func testQuietModeShowsNoNudge() {
    mirror.apply(snapshot(.active, style: .quiet))
    mirror.simulateDistraction()
    XCTAssertTrue(mirror.isDistracted, "still logged")
    mirror.agentNudge(message: "x")
    mirror.agentPraise(message: "y")
    if case .nudge = mirror.overlay { XCTFail("quiet mode must not nudge") }
    if case .toast(let m) = mirror.overlay, m == "y" { XCTFail("quiet mode must not praise") }
  }

  func testCompletedGoalsAreHandedToThePlannerAndPraised() {
    var done: [String] = []
    mirror.onGoalsCompleted = { done += $0.map(\.id) }
    mirror.apply(snapshot(.active))
    mirror.agentCompletedGoals([TBDFlowGoal(id: "t1", title: "Write report")])
    XCTAssertEqual(done, ["t1"])
    XCTAssertEqual(mirror.overlay, .toast(message: "Checked off: Write report"))
  }

  func testRelaunchInTheMiddleOfASessionRebriefsTheObserver() {
    mirror.apply(snapshot(.active))
    let second = RecordingObserver()
    let clock = self.clock
    _ = FlowSessionMirror(defaults: defaults, settings: settings, timeline: timeline, observer: second, now: { clock.now })
    XCTAssertEqual(second.events, ["start(rebrief)"])
  }

  func testAnExpiredSessionIsNotRestored() {
    mirror.apply(snapshot(.active))
    clock.set("2026-10-05T11:00:00Z")
    let second = RecordingObserver()
    let clock = self.clock
    let relaunched = FlowSessionMirror(defaults: defaults, settings: settings, timeline: timeline, observer: second, now: { clock.now })
    XCTAssertEqual(relaunched.snapshot.phase, .idle)
    XCTAssertEqual(second.events, [])
  }

  func testNoObserverDoesNothing() {
    let none = FlowSessionMirror(defaults: defaults, settings: settings, timeline: timeline, observer: nil, now: { Date() })
    none.apply(snapshot(.active))
    XCTAssertEqual(none.snapshot.phase, .active)
    XCTAssertTrue(none.observer is FlowNoObserver)
    XCTAssertEqual(none.observer.status, "Observer: not set up yet")
  }

  // MARK: Toasts wait for the nudge, the tub and the "Time's up" bubble (review 5)

  func testAToastDoesNotReplaceANudgeAndShowsWhenTheNudgeIsGone() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    let nudge = mirror.overlay
    mirror.toast("Start: Write report")
    XCTAssertEqual(mirror.overlay, nudge, "the nudge stays")
    XCTAssertEqual(mirror.queuedToastMessages, ["Start: Write report"])
    mirror.agentReportedFocusChange(isDistracted: false)  // the nudge goes
    XCTAssertEqual(mirror.overlay, .toast(message: "Start: Write report"))
    XCTAssertEqual(mirror.queuedToastMessages, [])
  }

  func testAToastDoesNotReplaceTheTubOrTheEndedBubble() {
    mirror.apply(snapshot(.active))
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    XCTAssertEqual(mirror.overlay, .onBreak)
    mirror.toast("Reminder one")
    XCTAssertEqual(mirror.overlay, .onBreak)
    mirror.debugHideOverlay()
    XCTAssertEqual(mirror.overlay, .toast(message: "Reminder one"))

    mirror.apply(snapshot(.active))  // the break is over
    clock.set("2026-10-05T10:30:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.overlay, .sessionEnded)
    mirror.toast("Reminder two")
    XCTAssertEqual(mirror.overlay, .sessionEnded, "the Time's up bubble stays until the person answers")
    mirror.dismissOverlay()
    XCTAssertEqual(mirror.overlay, .toast(message: "Reminder two"))
  }

  func testQueuedToastsAreFirstInFirstOutAtMostThreeAndNotRepeated() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    for text in ["A", "B", "B", "C", "D", "E"] { mirror.toast(text) }
    XCTAssertEqual(mirror.queuedToastMessages, ["C", "D", "E"], "three at most; the oldest go; a repeat is queued once")
    mirror.agentReportedFocusChange(isDistracted: false)
    XCTAssertEqual(mirror.overlay, .toast(message: "C"))
    mirror.dismissOverlay()
    XCTAssertEqual(mirror.overlay, .toast(message: "D"), "the next one follows in order")
    mirror.dismissOverlay()
    XCTAssertEqual(mirror.overlay, .toast(message: "E"))
    mirror.dismissOverlay()
    XCTAssertEqual(mirror.overlay, .hidden)
  }

  func testAnAnswerToTheNudgeStillReplacesIt() {
    mirror.apply(snapshot(.active))
    mirror.simulateDistraction()
    mirror.respondBackToWork()
    XCTAssertEqual(mirror.overlay, .toast(message: "Nice! Keep at it"))
  }

  func testNewSessionReplacesTheEndedBubble() {
    mirror.apply(snapshot(.active))
    clock.set("2026-10-05T10:30:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.overlay, .sessionEnded)
    mirror.apply(snapshot(.active, endsAt: "12:00:00Z"))
    XCTAssertEqual(mirror.overlay, .toast(message: "Your flow session starts now!"))
  }

  func testAGoalsChangeDuringABreakDoesNotShowTheTubAgainOrPauseTwice() {
    mirror.apply(snapshot(.active))
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    mirror.debugHideOverlay()  // the tub went away by itself
    XCTAssertEqual(observer.events, ["start", "pause"])
    var changed = snapshot(.onBreak, breakEndsAt: "09:40:00Z")
    changed.goals = [TBDFlowGoal(id: "t1", title: "Write report"), TBDFlowGoal(id: "t2", title: "Call Anna")]
    mirror.apply(changed)
    XCTAssertEqual(mirror.overlay, .hidden, "no second tub")
    XCTAssertEqual(observer.events, ["start", "pause", "goals"], "the observer gets the goals and no second pause")
  }

  // MARK: Relaunch during a break (review 14)

  func testRelaunchDuringABreakHandsTheObserverThePausedSession() {
    mirror.apply(snapshot(.active))
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    let relaunched = makeMirror()  // restores the persisted break
    XCTAssertEqual(relaunched.snapshot.phase, .onBreak)
    let fresh = RecordingObserver()
    relaunched.setObserver(fresh)
    XCTAssertEqual(fresh.events, ["start(rebrief)"], "the observer is given the session (it starts paused from the phase)")
  }
}
