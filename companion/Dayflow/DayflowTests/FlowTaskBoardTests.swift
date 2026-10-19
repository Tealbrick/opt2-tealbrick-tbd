import XCTest
import TBDModels

@testable import TBD

/// A Task Board helper that never leaves the process: no Keychain, no network, no relay. It records every call.
@MainActor
final class FakeTaskBoardClient: FlowTaskBoardClient {
  enum Completion { case ok, hold, fail(String) }

  var accessValue: TBDAppAccess = .unlocked
  var connected = true
  var listResult: Result<TBDFlowTaskBoardList, Error> = .success(TBDFlowTaskBoardList(available: true))
  var completion: Completion = .ok
  private(set) var accessCalls = 0
  private(set) var connectionCalls = 0
  private(set) var listCalls = 0
  private(set) var completeCalls: [(issue: String, result: String)] = []
  /// While a hold is pending, the call waits here until the test resumes it (the owner's approval).
  var approve: CheckedContinuation<Void, Never>?

  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  func access() async -> TBDAppAccess { accessCalls += 1; return accessValue }
  func agentConnected() async -> Bool { connectionCalls += 1; return connected }
  func list() async throws -> TBDFlowTaskBoardList { listCalls += 1; return try listResult.get() }

  func complete(issue: String, result: String, onStatus: @escaping @MainActor (String) -> Void) async throws -> String {
    completeCalls.append((issue, result))
    switch completion {
    case .ok: return "done"
    case .fail(let message): throw Failure(message: message)
    case .hold:
      onStatus("Waiting for owner approval")
      await withCheckedContinuation { approve = $0 }
      return "done"
    }
  }
}

/// F4: which list Flow shows, Task Board tasks, "Looks done", and the done-only-on-tap path.
@MainActor
final class FlowTaskBoardTests: FlowTestCase {
  private let day = "2026-10-05"
  private var fake: FakeTaskBoardClient!

  override func setUp() async throws {
    try await super.setUp()
    fake = FakeTaskBoardClient()
  }

  private let eyal = TBDFlowTaskBoardIssue(id: "iss_eyal", title: "Reply to Eyal", project: "Ops", status: .inProgress, ready: false)
  private let weekly = TBDFlowTaskBoardIssue(id: "iss_weekly", title: "Weekly review", project: "Ops", status: .todo, ready: true)
  private let waiting = TBDFlowTaskBoardIssue(id: "iss_wait", title: "Blocked thing", project: "Ops", status: .todo, ready: false)

  private func source(_ issues: [TBDFlowTaskBoardIssue]? = nil) -> FlowTaskBoardSource {
    if let issues { fake.listResult = .success(TBDFlowTaskBoardList(available: true, issues: issues)) }
    let clock = self.clock
    return FlowTaskBoardSource(client: fake, now: { clock.now })
  }

  private func boardTask(_ store: TBDFlowStore, _ title: String = "Reply to Eyal", issue: String = "iss_eyal") throws -> TBDFlowTask {
    try store.addTask(
      title: title, day: day, startAt: at("09:00:00Z"), endAt: at("10:00:00Z"), source: .taskBoard, taskBoardID: issue,
      taskBoardProject: "Ops")
  }

  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { await Task.yield() }
  }

  // MARK: Source decision (licensed/unknown/unlicensed x connected x available)

  func testSourceDecisionTable() async {
    for access in [TBDAppAccess.unlocked, .unknown, .locked, .install] {
      for connected in [true, false] {
        for available in [true, false] {
          fake = FakeTaskBoardClient()
          fake.accessValue = access
          fake.connected = connected
          fake.listResult = .success(
            available ? TBDFlowTaskBoardList(available: true, issues: [eyal]) : TBDFlowTaskBoardList(available: false, reason: "no grant sentence"))
          let board = source()
          await board.recheck(force: true)
          let label = "\(access) connected=\(connected) available=\(available)"
          switch (access, connected, available) {
          case (.unlocked, true, true):
            XCTAssertEqual(board.mode, .taskBoard, label)
            XCTAssertEqual(board.issues.map(\.id), ["iss_eyal"], label)
            XCTAssertNil(board.notice, label)
          case (.unlocked, true, false):
            XCTAssertEqual(board.mode, .local(.notGranted("no grant sentence")), label)
            XCTAssertEqual(board.notice, "no grant sentence", "licensed but not granted shows the grant sentence")
            XCTAssertEqual(board.issues, [], label)
          case (.unlocked, false, _):
            XCTAssertEqual(board.mode, .local(.notConnected), label)
          case (.unknown, _, _):
            XCTAssertEqual(board.mode, .local(.checking), "unknown never locks and never switches: \(label)")
            XCTAssertEqual(board.notice, "Checking Task Board…")
          case (.locked, _, _):
            XCTAssertEqual(board.mode, .local(.notLicensed), label)
            XCTAssertEqual(board.notice, "Task list from Task Board: available with Task Board. Until then TBD keeps this list on this Mac.")
          case (.install, _, _):
            XCTAssertEqual(board.mode, .local(.installNeeded), label)
          }
          // The helper is asked for the list only for a paid app with a connected agent.
          XCTAssertEqual(fake.listCalls, access == .unlocked && connected ? 1 : 0, label)
          XCTAssertEqual(fake.connectionCalls, access == .unlocked ? 1 : 0, label)
        }
      }
    }
  }

  func testAFailedCheckFallsBackToLocalWithTheSentenceAndTheNextCheckRecovers() async {
    fake.listResult = .failure(FakeTaskBoardClient.Failure(message: "Task Board did not answer in time. Try again."))
    let board = source()
    await board.recheck(force: true)
    XCTAssertEqual(board.mode, .local(.failed("Task Board did not answer in time. Try again.")))
    XCTAssertEqual(board.notice, "Task Board did not answer in time. Try again.")
    fake.listResult = .success(TBDFlowTaskBoardList(available: true, issues: [eyal]))
    await board.recheck(force: true)
    XCTAssertEqual(board.mode, .taskBoard)
  }

  func testPageOpenSkipsACheckThatJustRanButForceDoesNot() async {
    let board = source([eyal])
    await board.recheck()
    await board.recheck()
    XCTAssertEqual(fake.listCalls, 1, "a second page open right away does not ask again")
    clock.advance(16)
    await board.recheck()
    XCTAssertEqual(fake.listCalls, 2)
    await board.recheck(force: true)
    XCTAssertEqual(fake.listCalls, 3)
    XCTAssertEqual(FlowTaskBoardSource.interval, 600)
  }

  func testASeededSourceNeverAsksTheHelper() async {
    let board = source()
    board.seed(mode: .taskBoard, issues: [eyal])
    await board.recheck(force: true)
    XCTAssertEqual([fake.accessCalls, fake.connectionCalls, fake.listCalls], [0, 0, 0])
    XCTAssertEqual(board.mode, .taskBoard)
  }

  // MARK: Adding from Task Board

  func testAddFromTaskBoardMakesTaskBoardTasksWithTheTimeboxAndSkipsWhatIsAlreadyThere() throws {
    let board = source([eyal, weekly, waiting])
    board.seed(mode: .taskBoard, issues: [eyal, weekly, waiting])
    let planner = makePlanner(taskBoard: board)
    let added = try planner.addFromTaskBoard([
      .init(issue: eyal, startAt: at("09:40:00Z"), endAt: at("11:30:00Z")),
      .init(issue: weekly, startAt: nil, endAt: nil),
    ])
    XCTAssertEqual(added, 2)
    let tasks = planner.tasks.sorted { $0.title < $1.title }
    XCTAssertEqual(tasks.map(\.title), ["Reply to Eyal", "Weekly review"])
    XCTAssertEqual(tasks.map(\.source), [.taskBoard, .taskBoard])
    XCTAssertEqual(tasks.map(\.taskBoardID), ["iss_eyal", "iss_weekly"])
    XCTAssertEqual(tasks.map(\.taskBoardProject), ["Ops", "Ops"])
    XCTAssertEqual(tasks[0].startAt, at("09:40:00Z"))
    XCTAssertNil(tasks[1].startAt)
    XCTAssertEqual(tasks.map(\.status), [.todo, .todo], "adding never writes to Task Board and never closes anything")
    XCTAssertEqual(fake.completeCalls.count, 0)
    // The same issue again is skipped.
    XCTAssertEqual(try planner.addFromTaskBoard([.init(issue: eyal, startAt: nil, endAt: nil)]), 0)
    XCTAssertEqual(planner.tasks.count, 2)
    // The sheet offers in-progress first, then ready; an issue that waits on a dependency is not offered.
    XCTAssertEqual(TBDFlowTaskBoardList(available: true, issues: [weekly, waiting, eyal]).pickable.map(\.id), ["iss_eyal", "iss_weekly"])
  }

  // MARK: Plan paste while the source is Task Board

  func testPastedPlanLinesLinkToOwnerIssuesAndTheRestStayLocal() throws {
    let board = source()
    board.seed(mode: .taskBoard, issues: [eyal, weekly])
    let planner = makePlanner(taskBoard: board)
    let text = "09:00-10:00 reply to eyal\n10:00-11:00 Something only here\nTODO Weekly review"
    let preview = planner.linked(try planner.previewPlan(text: text, day: day, timeZone: Self.utc.timeZone))
    XCTAssertEqual(preview.drafts.map(\.taskBoardID), ["iss_eyal", nil, "iss_weekly"])
    XCTAssertEqual(preview.drafts[0].title, "Reply to Eyal", "the issue's own title is the snapshot")
    let result = try planner.commitPlan(preview, text: text, day: day, idempotencyKey: "paste-1", timeZone: Self.utc.timeZone)
    XCTAssertEqual(result.tasks.map(\.source), [.taskBoard, .local, .taskBoard])
    XCTAssertEqual(planner.tasks.filter { $0.source == .taskBoard }.count, 2)
    XCTAssertEqual(fake.completeCalls.count, 0, "pasting writes nothing to Task Board, and creates no issue")
    XCTAssertEqual(fake.listCalls + fake.completeCalls.count, 0)
  }

  func testPasteDoesNotLinkWhileTheListIsOnThisMac() throws {
    let board = source()  // never checked: local, checking
    let planner = makePlanner(taskBoard: board)
    let preview = planner.linked(try planner.previewPlan(text: "09:00-10:00 Reply to Eyal", day: day, timeZone: Self.utc.timeZone))
    XCTAssertEqual(preview.drafts.map(\.taskBoardID), [nil])
  }

  // MARK: Looks done

  func testObserverDetectionTicksALocalTaskButOnlyFlagsATaskBoardTask() throws {
    let store = makeStore()
    let local = try store.addTask(title: "Local report", day: day, startAt: at("09:00:00Z"), endAt: at("10:00:00Z"))
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    planner.detectedCompletion(taskID: local.id)
    planner.detectedCompletion(taskID: board.id)
    XCTAssertEqual(planner.tasks.first { $0.id == local.id }?.status, .done, "a local task is ticked as before")
    let flagged = try XCTUnwrap(planner.tasks.first { $0.id == board.id })
    XCTAssertEqual(flagged.status, .todo, "a Task Board task is NOT done")
    XCTAssertNotNil(flagged.looksDoneAt)
    XCTAssertEqual(fake.completeCalls.count, 0, "nothing is written to Task Board")
    XCTAssertEqual(planner.taskBoardRows[board.id], nil)
  }

  func testLooksDoneHasItsOwnToastAndNoCheckedOffToast() throws {
    let store = makeStore()
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    planner.start()
    defer { planner.stop() }
    XCTAssertEqual(mirror.snapshot.phase, .active)
    mirror.agentCompletedGoals([TBDFlowGoal(id: board.id, title: "Reply to Eyal")])
    XCTAssertEqual(mirror.overlay, .toast(message: "Looks done: Reply to Eyal. Mark it done on Task Board when you are ready."))
    XCTAssertEqual(planner.tasks.first?.status, .todo)
    // The observer says it again: no new toast, nothing changes.
    mirror.debugHideOverlay()
    mirror.agentCompletedGoals([TBDFlowGoal(id: board.id, title: "Reply to Eyal")])
    XCTAssertEqual(mirror.overlay, .hidden)
  }

  func testNotYetClearsTheHintForThirtyMinutesThenAReDetectionBringsItBack() throws {
    let store = makeStore()
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    planner.detectedCompletion(taskID: board.id)
    XCTAssertNotNil(planner.tasks.first?.looksDoneAt)
    planner.dismissLooksDone(try XCTUnwrap(planner.tasks.first))
    XCTAssertNil(planner.tasks.first?.looksDoneAt)
    clock.advance(20 * 60)
    planner.detectedCompletion(taskID: board.id)
    XCTAssertNil(planner.tasks.first?.looksDoneAt, "20 minutes later it stays quiet")
    clock.advance(11 * 60)
    planner.detectedCompletion(taskID: board.id)
    XCTAssertNotNil(planner.tasks.first?.looksDoneAt, "after 30 minutes a new detection shows it again")
    XCTAssertEqual(fake.completeCalls.count, 0)
  }

  func testTheLooksDoneFlagSurvivesARestart() throws {
    let store = makeStore()
    let board = try boardTask(store)
    makePlanner(store: store, taskBoard: source()).detectedCompletion(taskID: board.id)
    let reopened = makePlanner(store: makeStore(), taskBoard: source())
    XCTAssertNotNil(reopened.tasks.first { $0.id == board.id }?.looksDoneAt)
  }

  // MARK: Done only on the person's tap

  func testCompleteOnTapWritesOneCallWithTheMinutesAndThenTheTaskIsDone() async throws {
    let store = makeStore()
    let board = try boardTask(store)
    // 45 minutes of timeline that the person put on this task.
    let card = TimelineCard(
      recordId: 101, batchId: 1, startTimestamp: "9:00 AM", endTimestamp: "9:45 AM", category: "Work", subcategory: "", title: "Reply",
      summary: "", detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil, appSites: nil)
    try store.setCardLabel(cardID: "101", label: .onPlan, taskID: board.id, by: .person)
    let planner = makePlanner(store: store, taskBoard: source(), cards: [card])
    XCTAssertTrue(planner.needsTaskBoardConfirm(board))
    XCTAssertEqual(planner.minutesOnPlan(for: board), 45)

    await planner.completeOnTaskBoard(board)
    XCTAssertEqual(fake.completeCalls.count, 1)
    XCTAssertEqual(fake.completeCalls[0].issue, "iss_eyal")
    XCTAssertEqual(fake.completeCalls[0].result, "Done — tracked in TBD Flow, 45 min on plan")
    XCTAssertEqual(planner.tasks.first?.status, .done)
    XCTAssertNil(planner.taskBoardRows[board.id])
    XCTAssertFalse(planner.needsTaskBoardConfirm(try XCTUnwrap(planner.tasks.first)))
  }

  func testZeroMinutesIsAllowed() async throws {
    let store = makeStore()
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    await planner.completeOnTaskBoard(board)
    XCTAssertEqual(fake.completeCalls.map(\.result), ["Done — tracked in TBD Flow, 0 min on plan"])
  }

  func testAHoldShowsWaitingOnTheRowThenTheApprovalCompletesTheTask() async throws {
    let store = makeStore()
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    fake.completion = .hold
    let tap = Task { await planner.completeOnTaskBoard(board) }
    await waitFor { planner.taskBoardRows[board.id] == .waiting("Waiting for owner approval") }
    XCTAssertEqual(planner.taskBoardRows[board.id], .waiting("Waiting for owner approval"))
    XCTAssertEqual(planner.tasks.first?.status, .todo, "not done before the owner approves")
    // A second tap while it waits does nothing.
    await planner.completeOnTaskBoard(board)
    XCTAssertEqual(fake.completeCalls.count, 1)
    await waitFor { fake.approve != nil }
    fake.approve?.resume()
    await tap.value
    XCTAssertEqual(planner.tasks.first?.status, .done)
    XCTAssertNil(planner.taskBoardRows[board.id])
  }

  func testAnErrorShowsItsSentenceOnTheRowAndKeepsTheTaskOpen() async throws {
    let store = makeStore()
    let board = try boardTask(store)
    let planner = makePlanner(store: store, taskBoard: source())
    fake.completion = .fail("The owner declined marking this done on Task Board.")
    await planner.completeOnTaskBoard(board)
    XCTAssertEqual(planner.taskBoardRows[board.id], .failed("The owner declined marking this done on Task Board."))
    XCTAssertEqual(planner.tasks.first?.status, .todo)
    // Trying again after the error works.
    fake.completion = .ok
    await planner.completeOnTaskBoard(board)
    XCTAssertEqual(planner.tasks.first?.status, .done)
    XCTAssertEqual(fake.completeCalls.count, 2)
  }

  func testALocalTaskNeverGoesToTaskBoard() async throws {
    let store = makeStore()
    let local = try store.addTask(title: "Mine", day: day)
    let planner = makePlanner(store: store, taskBoard: source())
    XCTAssertFalse(planner.needsTaskBoardConfirm(local))
    await planner.completeOnTaskBoard(local)
    XCTAssertEqual(fake.completeCalls.count, 0)
    planner.toggleDone(local)
    XCTAssertEqual(planner.tasks.first?.status, .done)
    XCTAssertEqual(fake.completeCalls.count, 0)
  }

  func testACompletedIssueLeavesTheSheetListAtOnce() async throws {
    let board = source([eyal, weekly])
    await board.recheck(force: true)
    XCTAssertEqual(board.issues.count, 2)
    _ = try await board.complete(issue: "iss_eyal", result: "x") { _ in }
    XCTAssertEqual(board.issues.map(\.id), ["iss_weekly"])
  }
}
