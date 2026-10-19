import XCTest
import TBDModels

@testable import TBD

/// The observer on TBD model routes (slice F3): the verdict lifecycle of v1 on a fake capture and a scripted model.
@MainActor
final class FlowObserverTests: FlowObserverTestCase {
  // MARK: Gating

  func testOffByDefaultNothingRuns() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    XCTAssertFalse(setup.watching)
    await startSession()
    XCTAssertEqual(agent.status, "Observer: off")
    XCTAssertFalse(agent.isRunning)
    XCTAssertNil(agent.tick())
    XCTAssertEqual(screen.captures, 0)
    XCTAssertEqual(model.calls.count, 0)
  }

  func testNoRouteSaysWhy() async {
    setup.watching = true
    await startSession()
    XCTAssertEqual(agent.status, "Observer: Set up a model for the Flow observer in Flow › Observer.")
    XCTAssertNil(agent.tick())
    XCTAssertEqual(screen.captures, 0)
  }

  func testCloudWithoutConsentDoesNotCaptureOrSend() async throws {
    let connection = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
    try registry.saveConnection(connection, apiKey: "sk-test-1234")
    try registry.assign(TBDModelRoute(connectionID: connection.id, model: "claude-test"), to: "flow")
    setup.mode = .cloud
    setup.watching = true
    await startSession()
    XCTAssertEqual(agent.status, "Observer: The cloud model needs your choice first. Choose Cloud model in Flow › Observer.")
    XCTAssertNil(agent.tick())
    XCTAssertEqual(screen.captures, 0)
    XCTAssertEqual(model.calls.count, 0)
  }

  func testWaitsForASessionAndStartsWhenSwitchedOnMidSession() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    XCTAssertEqual(agent.status, "Observer: off")
    // The session starts with the switch off.
    await startSession()
    XCTAssertFalse(agent.isRunning)
    // The person turns the switch on: the observer takes the running session.
    setup.watching = true
    agent.reconfigure()
    await agent.startTask?.value
    XCTAssertTrue(agent.isRunning)
    // The session ends: back to waiting.
    agent.stop()
    XCTAssertFalse(agent.isRunning)
    XCTAssertEqual(agent.status, "Observer: waits for a session")
  }

  func testOllamaNotRunningStopsBeforeTheFirstCheck() async throws {
    try turnOn()
    localProblem = .ollamaNotRunning
    await startSession()
    XCTAssertEqual(agent.status, "Observer: Ollama is not running on this Mac.")
    XCTAssertFalse(agent.isRunning)
    XCTAssertEqual(agent.lastError, "Ollama is not running on this Mac.")
    XCTAssertNil(agent.tick())
  }

  func testStatusIsNotWatchingBeforeTheFirstCheck() async throws {
    try turnOn()
    await startSession()
    XCTAssertTrue(agent.isRunning)
    XCTAssertFalse(agent.status.hasPrefix("Last check"))
    XCTAssertEqual(agent.status, "Observer: waits for the first check")
  }

  // MARK: Evidence

  func testTextModeSendsOCRTextAndNeverTheImage() async throws {
    try turnOn(.textLocal)
    await startSession()
    await check()
    let call = try XCTUnwrap(model.calls.first)
    XCTAssertNil(call.imageJPEG, "text mode never attaches the image")
    XCTAssertTrue(call.userText.contains("Screen text (Apple OCR of the current screenshot):"))
    XCTAssertTrue(call.userText.contains(screen.text))
    XCTAssertTrue(call.userText.contains("Current time:"))
    XCTAssertEqual(screen.recognitions, 1)
    XCTAssertTrue(call.system.contains("text extracted from a screenshot"), "the briefing says the evidence is OCR text")
    XCTAssertEqual(call.config.baseURL.absoluteString, "http://localhost:11434/v1")
    XCTAssertEqual(call.config.model, "llama3.2:3b")
  }

  func testImageModeAttachesTheJPEGAndSkipsOCR() async throws {
    try turnOn(.visionLocal, modelName: "qwen2.5vl:3b")
    await startSession()
    await check()
    let call = try XCTUnwrap(model.calls.first)
    XCTAssertEqual(call.imageJPEG, FakeScreenSource.jpeg)
    XCTAssertTrue(call.userText.contains("Screenshot attached."))
    XCTAssertEqual(screen.recognitions, 0)
    XCTAssertTrue(call.system.contains("a screenshot of their screen"))
  }

  func testTextModeWritesNoFileAtAll() async throws {
    try turnOn(.textLocal)
    await startSession()
    let directory = try XCTUnwrap(agent.workDirectoryForTests)
    // While the model call runs, nothing is on disk: the OCR reads the image in memory.
    let first = agent.tick()
    XCTAssertEqual(files(in: directory), [], "no JPEG in text mode")
    await first?.value
    XCTAssertEqual(screen.captures, 1)
    XCTAssertEqual(screen.recognitions, 1)
    XCTAssertEqual(screen.urls, [], "text mode never asks for a JPEG file")
    XCTAssertEqual(files(in: directory), [])
    agent.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertNil(agent.workDirectoryForTests)
  }

  func testImageModeKeepsTheTempFileOnlyForTheCallAndRemovesItAfter() async throws {
    try turnOn(.visionLocal, modelName: "qwen2.5vl:3b")
    await startSession()
    let directory = try XCTUnwrap(agent.workDirectoryForTests)
    await check()
    XCTAssertEqual(screen.urls.count, 1)
    XCTAssertEqual(screen.urls.first?.deletingLastPathComponent().path, directory.path)
    XCTAssertEqual(files(in: directory), [], "the shot is gone after the check")
    agent.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testLeftoverObserverFoldersAreSweptAtStartAndAtStop() async throws {
    try turnOn(.visionLocal, modelName: "qwen2.5vl:3b")
    func leftover(_ name: String) throws -> URL {
      let url = folder.appendingPathComponent("TBDFlowObserver-\(name)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data("old shot".utf8).write(to: url.appendingPathComponent("shot-1.jpg"))
      return url
    }
    let other = folder.appendingPathComponent("KeepMe", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let crashed = try leftover("from-a-crash")
    await startSession()
    XCTAssertFalse(FileManager.default.fileExists(atPath: crashed.path), "swept at start")
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "other folders stay")
    let late = try leftover("made-while-running")
    agent.stop()
    XCTAssertFalse(FileManager.default.fileExists(atPath: late.path), "swept at stop")
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  func testTheScreenshotFileIsRemovedAfterAFailedCheckToo() async throws {
    try turnOn()
    await startSession()
    model.queueFailure(TBDFlowModelError.http(500, "boom"))
    let directory = try XCTUnwrap(agent.workDirectoryForTests)
    await check()
    XCTAssertEqual(files(in: directory), [])
  }

  // MARK: Verdicts

  func testOnTaskCheckSetsTheStatusLine() async throws {
    try turnOn()
    await startSession()
    await check()
    XCTAssertTrue(agent.status.hasPrefix("Last check "))
    XCTAssertTrue(agent.status.hasSuffix(" · on plan"), agent.status)
    XCTAssertEqual(agent.counters.checks, 1)
    XCTAssertFalse(mirror.isDistracted)
    XCTAssertEqual(mirror.overlay, .toast(message: "Your flow session starts now!"))
  }

  func testOffTaskNudgeShowsTheCreatureAndCounts() async throws {
    try turnOn()
    await startSession()
    model.queue(#"{"status":"off_task","action":"nudge","message":"Twitter can wait — 12 minutes left!","reason":"X feed"}"#)
    await check()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Twitter can wait — 12 minutes left!", escalated: false))
    XCTAssertTrue(mirror.isDistracted)
    XCTAssertTrue(agent.status.hasSuffix(" · off plan"), agent.status)
    XCTAssertEqual(agent.counters.nudges, 1)
    XCTAssertEqual(agent.counters.offPlanChecks, 1)
    // Back on task: the nudge goes away.
    model.queue(#"{"status":"on_task","action":"none"}"#)
    await check()
    XCTAssertFalse(mirror.isDistracted)
    XCTAssertEqual(mirror.overlay, .hidden)
    XCTAssertTrue(agent.status.hasSuffix(" · on plan"))
  }

  func testPraiseShowsAToast() async throws {
    try turnOn()
    await startSession()
    model.queue(#"{"status":"on_task","action":"praise","message":"Nice streak!"}"#)
    await check()
    XCTAssertEqual(mirror.overlay, .toast(message: "Nice streak!"))
  }

  func testQuietStyleNeverNudgesOrCounts() async throws {
    try turnOn()
    await startSession(style: .quiet)
    model.queue(#"{"status":"off_task","action":"nudge","message":"Hey","reason":"x"}"#)
    await check()
    XCTAssertEqual(agent.counters.nudges, 0)
    XCTAssertTrue(mirror.isDistracted, "the distraction is still logged")
    XCTAssertNotEqual(mirror.overlay, .nudge(message: "Hey", escalated: false))
    XCTAssertTrue(try XCTUnwrap(model.calls.first).system.contains("Quiet. The user asked for zero interruptions"))
  }

  func testCompletedGoalsGoToThePlannerEntryPointOnce() async throws {
    try turnOn()
    var completed: [[String]] = []
    mirror.onGoalsCompleted = { completed.append($0.map(\.id)) }
    await startSession()
    model.queue(#"{"status":"on_task","action":"none","completed_goals":["g1"]}"#)
    await check()
    XCTAssertEqual(completed, [["t1"]])
    XCTAssertEqual(mirror.overlay, .toast(message: "Checked off: Write report"))
    // Reported once.
    model.queue(#"{"status":"on_task","action":"none","completed_goals":["g1"]}"#)
    await check()
    XCTAssertEqual(completed, [["t1"]])
  }

  func testCompletedGoalChecksTheTaskOffInTheLocalList() async throws {
    try turnOn()
    let store = makeStore()
    let task = try store.addTask(title: "Write report", day: "2026-10-05", startAt: at("09:00:00Z"), endAt: at("10:30:00Z"))
    let planner = makePlanner(store: store)
    planner.start()
    defer { planner.stop() }
    // The planner's session carries the task id as the goal id.
    XCTAssertEqual(mirror.snapshot.goals.map(\.id), [task.id])
    agent.start(with: mirror.snapshot, rebrief: false)
    await agent.startTask?.value
    model.queue(#"{"status":"on_task","action":"none","completed_goals":["g1"]}"#)
    await check()
    XCTAssertEqual(store.task(id: task.id)?.status, .done)
  }

  func testUnparseableReplyIsOnTaskWithNoNudge() async throws {
    try turnOn()
    await startSession()
    model.queue("I think the user is fine.")
    await check()
    XCTAssertFalse(mirror.isDistracted)
    XCTAssertEqual(mirror.overlay, .toast(message: "Your flow session starts now!"))
    XCTAssertEqual(agent.counters.checks, 1)
  }

  func testFencedReplyWithProseIsParsed() async throws {
    try turnOn()
    await startSession()
    model.queue("Sure!\n```json\n{\"status\":\"off_task\",\"action\":\"nudge\",\"message\":\"Back!\"}\n```")
    await check()
    XCTAssertEqual(mirror.overlay, .nudge(message: "Back!", escalated: false))
  }

  // MARK: Failures

  func testFailuresStopTheObserverWithAStatus() async throws {
    try turnOn()
    settings.maxFailures = 2
    await startSession()
    model.queueFailure(TBDFlowModelError.unreachable(isLocal: true))
    model.queueFailure(TBDFlowModelError.unreachable(isLocal: true))
    await check()
    XCTAssertTrue(agent.isRunning, "one failure is not the end")
    XCTAssertEqual(agent.lastError, "Ollama is not running on this Mac.")
    await check()
    XCTAssertFalse(agent.isRunning)
    XCTAssertEqual(agent.status, "Observer stopped after 2 failed checks")
    XCTAssertNil(agent.tick())
    XCTAssertEqual(model.calls.count, 2)
    XCTAssertNil(agent.workDirectoryForTests)
  }

  func testASuccessResetsTheFailureCount() async throws {
    try turnOn()
    settings.maxFailures = 2
    await startSession()
    model.queueFailure(TBDFlowModelError.emptyReply)
    await check()
    await check()  // succeeds (fallback)
    model.queueFailure(TBDFlowModelError.emptyReply)
    await check()
    XCTAssertTrue(agent.isRunning)
  }

  func testACaptureFailureCountsAsAFailure() async throws {
    try turnOn()
    await startSession()
    screen.failure = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "No permission"])
    await check()
    XCTAssertEqual(agent.lastError, "No permission")
    XCTAssertEqual(model.calls.count, 0)
  }

  // MARK: Pause, notes, goals

  func testPausedSkipsTheCheckAndResumeContinues() async throws {
    try turnOn()
    await startSession()
    agent.pause()
    XCTAssertEqual(agent.status, "Observer: paused for your break")
    XCTAssertNil(agent.tick())
    XCTAssertEqual(screen.captures, 0)
    agent.resume()
    await check()
    XCTAssertEqual(screen.captures, 1)
    XCTAssertTrue(try XCTUnwrap(model.calls.first).userText.contains("The user just came back from their break."))
    XCTAssertEqual(timeline.breaks.count, 1)
  }

  func testAPausedSessionStartsPaused() async throws {
    try turnOn()
    let snap = snapshot(.onBreak, breakEndsAt: "09:40:00Z")
    agent.start(with: snap, rebrief: false)
    await agent.startTask?.value
    XCTAssertEqual(agent.status, "Observer: paused for your break")
    XCTAssertNil(agent.tick())
  }

  func testAChecksInFlightIsNotDoubled() async throws {
    try turnOn()
    await startSession()
    let first = agent.tick()
    XCTAssertNotNil(first)
    XCTAssertNil(agent.tick(), "skipped while one is in flight")
    await first?.value
    XCTAssertEqual(model.calls.count, 1)
  }

  func testNotesFromTheMirrorRepliesGoIntoTheNextCheckOnly() async throws {
    try turnOn()
    await startSession()
    agent.noteUserEvent("The user snoozed your nudge for 5 minutes.", markRefocused: false)
    await check()
    XCTAssertTrue(try XCTUnwrap(model.calls.first).userText.contains("The user snoozed your nudge for 5 minutes."))
    await check()
    XCTAssertFalse(model.calls[1].userText.contains("snoozed"))
  }

  func testGoalChangesAreToldWithFreshShortIds() async throws {
    try turnOn()
    await startSession()
    var changed = snapshot(.active)
    changed.goals = [TBDFlowGoal(id: "t2", title: "Reply to Eyal"), TBDFlowGoal(id: "t1", title: "Write report")]
    agent.goalsChanged(to: changed)
    await check()
    let text = try XCTUnwrap(model.calls.first).userText
    XCTAssertTrue(text.contains("GOALS UPDATED"))
    XCTAssertTrue(text.contains("- [g1] Reply to Eyal"))
    XCTAssertTrue(text.contains("- [g2] Write report"))
    XCTAssertTrue(text.contains("Newly added: Reply to Eyal"))
  }

  func testTheAlertStyleChangesTheNextBriefing() async throws {
    try turnOn()
    await startSession(style: .friendly)
    await check()
    XCTAssertTrue(model.calls[0].system.contains("Friendly. Give them slack"))
    var feisty = snapshot(.active, style: .feisty)
    feisty.goals = mirror.snapshot.goals
    agent.goalsChanged(to: feisty)
    await check()
    XCTAssertTrue(model.calls[1].system.contains("Feisty. Quick and stern"))
  }

  func testTheBriefingKeepsV1PlaceholdersFilled() async throws {
    try turnOn()
    await startSession()
    await check()
    let system = try XCTUnwrap(model.calls.first).system
    XCTAssertFalse(system.contains("{{"), "every placeholder is filled")
    XCTAssertTrue(system.contains("- [g1] Write report"))
    XCTAssertTrue(system.contains("Roughly every 15 seconds"))
    XCTAssertTrue(system.contains("Planned length: 60 minutes"))
    XCTAssertTrue(system.contains("This is an HTTP observer with no tools or filesystem access."))
    XCTAssertFalse(system.contains("timeline.json"), "no file hand-off")
    XCTAssertFalse(system.contains("Dayflow"))
  }

  func testTheTranscriptKeepsTheLastReplyAsContextAndIsCapped() async throws {
    try turnOn()
    await startSession()
    model.queue(#"{"status":"on_task","action":"none","reason":"first"}"#)
    await check()
    await check()
    XCTAssertTrue(model.calls[1].system.contains(#""reason":"first""#), "prior verdicts are context")
    for _ in 0..<210 { model.queue(#"{"status":"on_task","action":"none"}"#) }
    for _ in 0..<205 { await check() }
    XCTAssertEqual(agent.transcript.count, 200)
  }

  // MARK: Timeline (inline second object)

  func testTimelineTurnAppliesItems() async throws {
    try turnOn()
    await startSession()
    clock.advance(180)
    let start = FlowSessionTimeline.clock(timeline.sessionStartedAt)
    let end = FlowSessionTimeline.clock(clock.now)
    model.queue(
      #"{"status":"on_task","action":"none"}"# + "\n"
        + #"{"timeline":[{"start":"\#(start)","end":"\#(end)","kind":"focused","title":"Writing the report"}]}"#)
    await agent.requestTimelineNow()?.value
    XCTAssertEqual(timeline.entries.map(\.title), ["Writing the report"])
    let call = try XCTUnwrap(model.calls.first)
    XCTAssertTrue(call.userText.contains("TIMELINE UPDATE"))
    XCTAssertTrue(call.userText.contains("Current timeline:"))
    XCTAssertFalse(call.userText.contains("timeline.json"), "no file hand-off")
  }

  // MARK: Counters and page helpers

  func testSnoozesAreCountedForToday() async throws {
    try turnOn()
    await startSession()
    agent.userSnoozed()
    agent.userSnoozed()
    XCTAssertEqual(agent.counters.snoozes, 2)
    XCTAssertEqual(agent.counters.summary, "0 checks · 0 nudges · 2 snoozes")
    XCTAssertEqual(FlowObserverCounters(day: "d", checks: 312, nudges: 3, snoozes: 1).summary, "312 checks · 3 nudges · 1 snooze")
  }

  func testCountersRollOverWithTheDay() async throws {
    try turnOn()
    await startSession()
    agent.userSnoozed()
    clock.advance(36 * 3600)
    agent.refreshCounters()
    XCTAssertEqual(agent.counters.snoozes, 0)
  }

  func testJSONObjectsSkipBracesInStringsAndProse() {
    let reply = "ok {\"a\":\"}{\"} then ```{\"b\":{\"c\":1}}``` end"
    XCTAssertEqual(FlowDistractionAgent.jsonObjects(in: reply), ["{\"a\":\"}{\"}", "{\"b\":{\"c\":1}}"])
  }

  func testScreenTextFormatting() {
    XCTAssertEqual(FlowScreenText.format([("keep", 0.9), ("drop", 0.2), ("edge", 0.3)]), "keep\nedge")
    XCTAssertEqual(FlowScreenText.format([("drop", 0.1)]), "[no text detected on screen]")
    XCTAssertEqual(FlowScreenText.format([]), "[no text detected on screen]")
    let long = FlowScreenText.format([(String(repeating: "x", count: 5000), 0.9)])
    XCTAssertTrue(long.hasSuffix("\n[truncated]"))
    XCTAssertEqual(long.count, 4000 + "\n[truncated]".count)
  }

  func testThePlannerPutsTheSavedAlertStyleIntoTheSession() throws {
    defaults.set("feisty", forKey: FlowAgentSettings.alertStyleKey)
    let store = makeStore()
    try store.addTask(title: "Write report", day: "2026-10-05", startAt: at("09:00:00Z"), endAt: at("10:30:00Z"))
    let planner = makePlanner(store: store)
    planner.refresh()
    XCTAssertEqual(mirror.snapshot.alertStyle, .feisty)
    XCTAssertEqual(FlowAgentSettings(defaults: defaults).alertStyle, .feisty)
  }

  // MARK: Goal ids belong to the list that check sent (review 11)

  func testCompletedGoalsAreReadAgainstTheListThatCheckSent() async throws {
    try turnOn()
    var completed: [[String]] = []
    mirror.onGoalsCompleted = { completed.append($0.map(\.id)) }
    await startSession()  // the list is [t1 "Write report"]: g1 = t1
    model.queue(#"{"status":"on_task","action":"none","completed_goals":["g1"]}"#)
    let inFlight = agent.tick()
    // While the call runs, a task is added in front: now g1 would mean something else.
    var changed = snapshot(.active)
    changed.goals = [TBDFlowGoal(id: "t0", title: "Call Anna"), TBDFlowGoal(id: "t1", title: "Write report")]
    agent.goalsChanged(to: changed)
    await inFlight?.value
    XCTAssertEqual(completed, [["t1"]], "g1 of THAT check is t1, not the task that moved to the top")
  }

  // MARK: reconfigure follows the mirror (review 13)

  func testReconfigureRestartsFromTheMirrorSoABreakStaysPaused() async throws {
    try turnOn()
    await startSession()
    XCTAssertEqual(agent.status, "Observer: waits for the first check")
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))  // the agent was not told: the stored session is still active
    agent.reconfigure()
    await agent.startTask?.value
    XCTAssertEqual(agent.status, "Observer: paused for your break")
    XCTAssertNil(agent.tick(), "no check during the break")
    XCTAssertEqual(screen.captures, 0)
  }

  func testReconfigureWithNoLiveSessionInTheMirrorStopsTheObserver() async throws {
    try turnOn()
    await startSession()
    mirror.apply(.idle)
    agent.reconfigure()
    XCTAssertFalse(agent.isRunning)
    XCTAssertEqual(agent.status, "Observer: waits for a session")
    XCTAssertNil(agent.tick())
  }

  // MARK: Relaunch during a break (review 14)

  func testAnObserverHandedABreakSessionResumesAfterTheBreak() async throws {
    try turnOn()
    mirror.apply(snapshot(.active))
    mirror.apply(snapshot(.onBreak, breakEndsAt: "09:40:00Z"))
    // Relaunch: a new mirror restores the break and the real observer is plugged in.
    let relaunched = makeMirror()
    XCTAssertEqual(relaunched.snapshot.phase, .onBreak)
    relaunched.setObserver(agent)
    await agent.startTask?.value
    XCTAssertTrue(agent.isRunning)
    XCTAssertEqual(agent.status, "Observer: paused for your break")
    XCTAssertNil(agent.tick())
    // The break ends: the mirror resumes the observer and checks work again.
    relaunched.apply(snapshot(.active))
    await check()
    XCTAssertEqual(screen.captures, 1, "resume() worked after the break")
  }

  // MARK: A new session after an ended one starts a fresh timeline (review 10)

  func testANewSessionAfterAnEndedOneHasAFreshStartAndAFreshTimeline() async throws {
    try turnOn()
    let store = makeStore()
    try store.addTask(title: "Write report", day: "2026-10-05", startAt: at("09:00:00Z"), endAt: at("10:00:00Z"))
    let planner = makePlanner(store: store)
    mirror.setObserver(agent)
    planner.refresh()
    await agent.startTask?.value
    await check()
    XCTAssertEqual(timeline.sessionStartedAt, at("09:30:00Z"))
    XCTAssertFalse(timeline.observations.isEmpty)

    clock.set("2026-10-05T10:00:01Z")
    mirror.handleDeadline()
    XCTAssertEqual(mirror.snapshot.phase, .ended)
    clock.set("2026-10-05T10:10:00Z")
    try store.addTask(title: "Second round", day: "2026-10-05", startAt: at("10:10:00Z"), endAt: at("11:00:00Z"))
    planner.refresh()
    await agent.startTask?.value
    XCTAssertEqual(timeline.sessionStartedAt, at("10:10:00Z"), "a fresh session start")
    XCTAssertTrue(timeline.observations.isEmpty, "a fresh timeline")
    XCTAssertTrue(timeline.entries.isEmpty)
  }

  // MARK: A long error is a notice, not a tag (review 23)

  func testALongObserverErrorIsNotShownInsideTheTag() async throws {
    try turnOn()
    localProblem = .modelMissing("a-very-long-model-name:70b-instruct-q4_K_M")
    await startSession()
    let error = try XCTUnwrap(agent.lastError)
    XCTAssertGreaterThan(error.count, 50)
    XCTAssertTrue(agent.status.contains(error), "the status line carries the whole sentence")
    let tag = FlowView.observerTagText(status: agent.status, lastError: agent.lastError)
    XCTAssertEqual(tag, "Observer: needs attention", "the tag stays short; the sentence is in the notice under the header")
    // Short statuses stay as they are.
    XCTAssertEqual(FlowView.observerTagText(status: "Observer: off", lastError: nil), "Observer: off")
    XCTAssertEqual(FlowView.observerTagText(status: "Last check 10:42 · on plan", lastError: nil), "Last check 10:42 · on plan")
    XCTAssertEqual(
      FlowView.observerTagText(status: "Observer stopped after 3 failed checks", lastError: "The model did not answer in time."),
      "Observer stopped after 3 failed checks")
  }
}
