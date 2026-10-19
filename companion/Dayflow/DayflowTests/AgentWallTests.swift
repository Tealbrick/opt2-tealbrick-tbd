import XCTest

@testable import TBD

/// The Agents wall (WP-WALL): roster decode, slot rule, tones, counts, states, refresh rules, selection, scroll and the
/// rule that this code path starts no process.
@MainActor
final class AgentWallTests: XCTestCase {
  // MARK: Rows

  private func workspaceRow(
    _ id: String, _ name: String, state: String? = "online", purpose: String? = "Does things", harness: String? = "Codex"
  ) -> [String: Any] {
    var info: [String: Any] = [:]
    if let state { info["state"] = state }
    if let purpose { info["purpose"] = purpose }
    if let harness { info["harness"] = harness }
    return ["id": id, "name": name, "runtime": "workspace", "workspace": info]
  }

  private let ownRow: [String: Any] = ["id": "tbd-default", "name": "TBD", "runtime": "tbd-default"]

  private func roster(_ names: [String], state: String = "online") -> [WallAgent] {
    AgentWallRoster.decode([ownRow] + names.map { workspaceRow($0.lowercased(), $0, state: state) }).agents
  }

  // MARK: Decode

  func testOwnRowWithoutWorkspaceIsTBDOnlineBuiltIn() {
    let result = AgentWallRoster.decode([ownRow])
    XCTAssertEqual(result.agents.count, 1)
    let own = result.agents[0]
    XCTAssertTrue(own.own)
    XCTAssertEqual(own.state, .online)
    XCTAssertEqual(own.harness, "Built in")
    XCTAssertEqual(own.purpose, "Your own agent")
    XCTAssertEqual(own.name, "TBD")
    XCTAssertNil(result.notice)
  }

  func testRosterNoticeOnTheOwnRowBecomesTheNotice() {
    var row = ownRow
    row["rosterNotice"] = "The other agents of this workspace could not be loaded (offline). TBD tries again in a minute."
    XCTAssertEqual(AgentWallRoster.decode([row]).notice, row["rosterNotice"] as? String)
    row["rosterNotice"] = "   "
    XCTAssertNil(AgentWallRoster.decode([row]).notice)
  }

  func testWorkspaceRowsKeepStatePurposeAndHarness() {
    let result = AgentWallRoster.decode([ownRow, workspaceRow("a", "Henry", state: "online", purpose: "Triage", harness: "Claude Agent SDK")])
    XCTAssertEqual(result.agents.count, 2)
    let henry = result.agents[1]
    XCTAssertFalse(henry.own)
    XCTAssertEqual(henry.id, "a")
    XCTAssertEqual(henry.state, .online)
    XCTAssertEqual(henry.purpose, "Triage")
    XCTAssertEqual(henry.harness, "Claude Agent SDK")
  }

  func testPausedWinsOverOnline() {
    var row = workspaceRow("a", "Henry", state: "online")
    row["paused"] = true
    XCTAssertEqual(AgentWallRoster.decode([ownRow, row]).agents[1].state, .paused)
    var info = row["workspace"] as! [String: Any]
    info["paused"] = true
    row["workspace"] = info
    row["paused"] = nil
    XCTAssertEqual(AgentWallRoster.decode([ownRow, row]).agents[1].state, .paused)
    XCTAssertEqual(AgentWallRoster.decode([ownRow, workspaceRow("a", "Henry", state: "paused")]).agents[1].state, .paused)
  }

  func testUnknownOrMissingStateIsOffline() {
    for state in ["connected", "pending", "", "ONLINE?", nil] as [String?] {
      XCTAssertEqual(AgentWallRoster.decode([ownRow, workspaceRow("a", "Henry", state: state)]).agents[1].state, .offline, "\(state ?? "nil")")
    }
    XCTAssertEqual(AgentWallRoster.decode([ownRow, workspaceRow("a", "Henry", state: " Online ")]).agents[1].state, .online)
  }

  func testMissingFieldsGetDefaultsAndBadRowsAreSkipped() {
    let rows: [Any] = [
      ownRow,
      ["id": "x", "workspace": [:]] as [String: Any],  // no name: the id is the name
      ["name": "Named", "workspace": ["harness": NSNull(), "purpose": 3]] as [String: Any],  // no id: the name is the id
      ["workspace": ["state": "online"]] as [String: Any],  // neither: skipped
      "not a row", 42, NSNull(),
      ["id": "x", "name": "Dupe", "workspace": ["state": "online"]] as [String: Any],  // same id: skipped
    ]
    let result = AgentWallRoster.decode(rows)
    XCTAssertEqual(result.agents.map(\.name), ["TBD", "x", "Named"])
    XCTAssertEqual(result.agents[1].purpose, "")
    XCTAssertEqual(result.agents[1].harness, "")
    XCTAssertEqual(result.agents[2].id, "Named")
    XCTAssertEqual(result.agents[2].harness, "")
    XCTAssertEqual(result.agents[2].state, .offline)
  }

  func testGarbageAnswersStillGiveTBD() {
    for value in [nil, "text", 7, [String: Any](), [Any]()] as [Any?] {
      XCTAssertEqual(AgentWallRoster.decode(value).agents, [.tbd])
    }
  }

  func testAnAnswerWithoutTBDGetsTBDFirst() {
    let agents = AgentWallRoster.decode([workspaceRow("a", "Henry")]).agents
    XCTAssertEqual(agents.map(\.name), ["TBD", "Henry"])
    XCTAssertTrue(agents[0].own)
  }

  func testOnlyOneOwnRowCounts() {
    var second = ownRow
    second["id"] = "other"
    XCTAssertEqual(AgentWallRoster.decode([ownRow, second]).agents.count, 1)
  }

  // MARK: Slot rule

  func testSlotCourseAndColumnFollowTheRule() {
    XCTAssertEqual((0..<9).map { AgentWallPlan.slot($0).course }, [4, 3, 5, 2, 6, 1, 7, 0, 4])
    XCTAssertEqual((0..<4).map { AgentWallPlan.slot($0).column }, [1, 2, 3, 4])
  }

  func testTBDIsAlwaysSlotZeroAndTheRestAreByNameIgnoringCase() {
    let ordered = AgentWallPlan.ordered(AgentWallRoster.decode([workspaceRow("1", "zed"), ownRow, workspaceRow("2", "Alpha"), workspaceRow("3", "beta")]).agents)
    XCTAssertEqual(ordered.map(\.name), ["TBD", "Alpha", "beta", "zed"])
    // A workspace agent called "Aaa" does not take slot 0.
    XCTAssertEqual(AgentWallPlan.ordered(roster(["Aaa"])).first?.name, "TBD")
    let plan = AgentWallPlan(agents: ordered, showOffline: true)
    XCTAssertEqual(plan.bricks[0].agentID, "tbd-default")
    XCTAssertEqual(plan.bricks[0].course, 4)
    XCTAssertEqual(plan.bricks[0].startColumn, 1)
  }

  func testSlotsAreStableWhenAnAgentIsAdded() {
    let before = AgentWallPlan(agents: roster(["Atlas", "Nova"]), showOffline: true)
    // "Zed" sorts last: nobody moves.
    let afterLast = AgentWallPlan(agents: roster(["Atlas", "Nova", "Zed"]), showOffline: true)
    for brick in before.bricks {
      XCTAssertTrue(afterLast.bricks.contains(brick), "\(brick.agentID) did not move")
    }
    XCTAssertEqual(afterLast.bricks.count, before.bricks.count + 1)
    // "Henry" sorts between: only the agents after it move, TBD and the ones before it stay.
    let afterMiddle = AgentWallPlan(agents: roster(["Atlas", "Henry", "Nova"]), showOffline: true)
    func slot(_ plan: AgentWallPlan, _ id: String) -> [Int] { plan.bricks.filter { $0.agentID == id }.flatMap { [$0.course, $0.startColumn] } }
    XCTAssertEqual(slot(afterMiddle, "tbd-default"), slot(before, "tbd-default"))
    XCTAssertEqual(slot(afterMiddle, "atlas"), slot(before, "atlas"))
    XCTAssertNotEqual(slot(afterMiddle, "nova"), slot(before, "nova"))
  }

  func testTheSameRosterGivesTheSameWall() {
    let a = AgentWallPlan(agents: roster(["Atlas", "Nova"]), showOffline: true)
    let b = AgentWallPlan(agents: roster(["Nova", "Atlas"]), showOffline: true)
    XCTAssertEqual(a, b)
  }

  func testOfflineAgentKeepsItsSlotWhenHidden() {
    var agents = roster(["Atlas", "Henry", "Nova"])
    agents = agents.map { $0.name == "Henry" ? WallAgent(id: $0.id, name: $0.name, purpose: $0.purpose, harness: $0.harness, state: .offline, own: false) : $0 }
    let shown = AgentWallPlan(agents: agents, showOffline: true)
    let hidden = AgentWallPlan(agents: agents, showOffline: false)
    XCTAssertEqual(shown.bricks.count, 4)
    XCTAssertEqual(hidden.bricks.count, 3)
    XCTAssertFalse(hidden.bricks.contains { $0.agentID == "henry" })
    XCTAssertFalse(hidden.callouts.contains { $0.agentID == "henry" })
    for brick in hidden.bricks { XCTAssertTrue(shown.bricks.contains(brick), "\(brick.agentID) stays in its slot") }
  }

  func testTheLoopGrowsSoTwoSlotsNeverShareACell() {
    let names = (0..<30).map { String(format: "agent%02d", $0) }
    let plan = AgentWallPlan(agents: roster(names), showOffline: true)
    XCTAssertEqual(plan.bricks.count, 31)
    XCTAssertGreaterThanOrEqual(plan.loopColumns, 32)
    XCTAssertEqual(plan.loopColumns % AgentWallTile.bricksPerCourse, 0)
    let cells = plan.bricks.flatMap { b in b.columns.map { "\(b.course)-\($0 % plan.loopColumns)" } }
    XCTAssertEqual(Set(cells).count, cells.count)
    // Small rosters keep the three-tile loop of the approved mockup.
    XCTAssertEqual(AgentWallPlan(agents: roster(["Atlas"]), showOffline: true).loopColumns, 24)
  }

  // MARK: Tones

  func testToneMapping() {
    let agents = AgentWallRoster.decode([
      ownRow, workspaceRow("1", "On", state: "online"), workspaceRow("2", "Pa", state: "paused"), workspaceRow("3", "Off", state: "offline"),
    ]).agents
    XCTAssertEqual(agents.map(\.tone), [.own, .online, .paused, .offline])
    XCTAssertEqual(agents.map { $0.tone.photo }, [.deep, .teal, .amber, nil], "offline is the plain wall")
    XCTAssertEqual(AgentWallPhoto.deep.assetName, "AgentWallTealdeep")
    let plan = AgentWallPlan(agents: agents, showOffline: true)
    XCTAssertEqual(plan.bricks.first { $0.agentID == "tbd-default" }?.tone, .own)
    XCTAssertEqual(plan.bricks.first { $0.agentID == "3" }?.tone, .offline)
    XCTAssertTrue(plan.bricks.allSatisfy { $0.length == 1 })
  }

  func testCalloutsHaveTwoShortLines() {
    let plan = AgentWallPlan(agents: AgentWallRoster.decode([ownRow, workspaceRow("1", "Henry", state: "paused", harness: "Codex")]).agents, showOffline: true)
    XCTAssertEqual(plan.callouts.first { $0.agentID == "1" }?.meta, "Codex\npaused")
    XCTAssertEqual(plan.callouts.first { $0.agentID == "tbd-default" }?.meta, "Built in\nonline")
    let noHarness = AgentWallPlan(agents: AgentWallRoster.decode([ownRow, workspaceRow("1", "Henry", harness: nil)]).agents, showOffline: true)
    XCTAssertEqual(noHarness.callouts.first { $0.agentID == "1" }?.meta, "online")
  }

  // MARK: Counts, states, toggle

  private func state(_ rows: [[String: Any]], signedIn: Bool = true, loaded: Bool = true) -> AgentWallState {
    AgentWallState(roster: .decode(rows), signedIn: signedIn, loaded: loaded)
  }

  func testCountsIncludeTBDAndOffline() {
    let s = state([ownRow, workspaceRow("1", "A"), workspaceRow("2", "B", state: "paused"), workspaceRow("3", "C", state: "offline"), workspaceRow("4", "D", state: "weird")])
    let counts = s.counts
    XCTAssertEqual(counts.total, 5)
    XCTAssertEqual(counts.online, 2, "TBD and A")
    XCTAssertEqual(counts.paused, 1)
    XCTAssertEqual(counts.offline, 2)
    XCTAssertEqual(counts.online + counts.paused + counts.offline, counts.total)
  }

  func testShowOfflineOffRemovesThemFromWallAndListButNotFromCounts() {
    let s = state([ownRow, workspaceRow("1", "A"), workspaceRow("3", "C", state: "offline")])
    XCTAssertEqual(s.visible(showOffline: true).map(\.name), ["TBD", "A", "C"])
    XCTAssertEqual(s.visible(showOffline: false).map(\.name), ["TBD", "A"])
    XCTAssertEqual(s.counts.offline, 1)
    XCTAssertEqual(s.counts.total, 3)
  }

  func testShowOfflineKeyAndDefault() {
    let key = "agentWallShowOffline"
    let saved = UserDefaults.standard.object(forKey: key)
    defer { if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertNil(UserDefaults.standard.object(forKey: key), "no stored value: the page's default (true) applies")
    let source = try? String(contentsOfFile: Self.sourceFolder("Views/UI/Agents") + "/AgentWallView.swift", encoding: .utf8)
    XCTAssertTrue(source?.contains("@AppStorage(\"agentWallShowOffline\") private var showOffline = true") == true)
  }

  func testSignedOutShowsTBDAndTheSignInNotice() {
    let s = state([ownRow, workspaceRow("1", "A")], signedIn: false)
    XCTAssertEqual(s.mode, .signedOut)
    XCTAssertEqual(s.agents, [.tbd])
    XCTAssertEqual(s.notice?.text, "Sign in to Teal Brick to see your workspace agents.")
    XCTAssertEqual(s.notice?.offersAccount, true)
    XCTAssertEqual(s.counts.total, 1)
  }

  func testSignedInWithoutWorkspaceAgentsShowsTheApprovedEmptyNotice() {
    let s = state([ownRow])
    XCTAssertEqual(s.mode, .empty)
    XCTAssertEqual(s.notice?.text, "Connect agents to your workspace in Portal. They appear here.")
    XCTAssertEqual(s.notice?.offersAccount, false)
    XCTAssertEqual(s.agents.count, 1)
    // Before the first answer there is nothing to say yet.
    XCTAssertNil(state([ownRow], loaded: false).notice)
  }

  func testRosterWithAgentsHasNoNoticeUnlessTheHelperSentOne() {
    XCTAssertEqual(state([ownRow, workspaceRow("1", "A")]).mode, .roster)
    XCTAssertNil(state([ownRow, workspaceRow("1", "A")]).notice)
    var row = ownRow
    row["rosterNotice"] = "Portal did not answer."
    let withNotice = state([row, workspaceRow("1", "A")])
    XCTAssertEqual(withNotice.notice?.text, "Portal did not answer.")
    XCTAssertEqual(withNotice.notice?.needsYou, true)
    XCTAssertEqual(state([row]).notice?.text, "Portal did not answer.", "a failure replaces the connect hint")
  }

  // MARK: Refresh rules

  @MainActor
  final class FakeClient: AgentWallRosterClient {
    var calls = 0
    var answer: Any = [] as [Any]
    var failure = false
    var blocking = false
    private var gate: CheckedContinuation<Void, Never>?
    func listAgents() async throws -> Any {
      calls += 1
      if blocking { await withCheckedContinuation { gate = $0 } }
      if failure { throw CocoaError(.fileReadUnknown) }
      return answer
    }
    func release() { gate?.resume(); gate = nil; blocking = false }
  }

  private func makeStore(_ client: FakeClient, signedIn: Bool = true, active: Bool = true) -> AgentWallRosterStore {
    AgentWallRosterStore(client: client, signedIn: { signedIn }, isAppActive: { active })
  }

  private func waitUntil(_ what: String = "", _ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(condition(), what)
  }

  func testNoCallWhileThePageIsNotVisible() async {
    let client = FakeClient()
    let store = makeStore(client)
    await store.refresh()
    store.appDidBecomeActive()
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(client.calls, 0)
    XCTAssertFalse(store.isPolling)
  }

  func testAppearReadsOnceAndStartsTheTimerAndDisappearStopsBoth() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil("first read") { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertTrue(store.isPolling)
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Henry"])
    XCTAssertEqual(store.state.mode, .roster)
    XCTAssertEqual(AgentWallRosterStore.interval, 60)
    store.pageDidDisappear()
    XCTAssertFalse(store.isPolling)
    store.appDidBecomeActive()
    store.visibleTimerFired()
    await store.refresh()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(client.calls, 1, "no call after the page left")
  }

  func testTimerTickAndAppFocusReadWhileVisible() async {
    let client = FakeClient()
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing }
    store.visibleTimerFired()
    await waitUntil("tick") { client.calls == 2 && !store.isRefreshing }
    store.appDidBecomeActive()
    await waitUntil("focus") { client.calls == 3 && !store.isRefreshing }
    store.pageDidDisappear()
  }

  func testABackgroundAppDoesNotReadOnTheTick() async {
    let client = FakeClient()
    let store = makeStore(client, active: false)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing }
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(client.calls, 1)
    store.pageDidDisappear()
  }

  func testNoOverlappingCalls() async {
    let client = FakeClient()
    client.blocking = true
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil("first call is running") { client.calls == 1 && store.isRefreshing }
    await store.refresh()
    store.appDidBecomeActive()
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(client.calls, 1, "a call is in flight: no second call")
    client.release()
    await waitUntil("done") { !store.isRefreshing }
    store.visibleTimerFired()
    await waitUntil("next read") { client.calls == 2 && !store.isRefreshing }
    store.pageDidDisappear()
  }

  func testSignedOutMakesNoCallAndShowsTBDWithTheNotice() async {
    let client = FakeClient()
    let store = makeStore(client, signedIn: false)
    store.pageDidAppear()
    await waitUntil { store.state.loaded }
    XCTAssertEqual(client.calls, 0)
    XCTAssertEqual(store.state.mode, .signedOut)
    XCTAssertEqual(store.state.agents, [.tbd])
    store.pageDidDisappear()
  }

  func testAFailureKeepsTheLastRosterAndAddsANotice() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    client.failure = true
    store.visibleTimerFired()
    await waitUntil("failed read") { client.calls == 2 && !store.isRefreshing }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Henry"])
    XCTAssertEqual(store.state.notice?.needsYou, true)
    XCTAssertTrue(store.state.notice?.text.contains("could not be loaded") == true)
    store.pageDidDisappear()
  }

  func testASeededStoreNeverAsksTheHelper() async {
    let client = FakeClient()
    let store = makeStore(client)
    store.seed(.decode([ownRow, workspaceRow("1", "Henry")]), signedIn: true)
    store.pageDidAppear()
    await store.refresh()
    store.appDidBecomeActive()
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(client.calls, 0)
    XCTAssertFalse(store.isPolling)
    XCTAssertEqual(store.state.agents.count, 2)
  }

  // MARK: Selection

  func testSelectionTogglesAndClearsOnAnEmptySpot() {
    XCTAssertEqual(AgentWallSelection.toggled(current: nil, hit: "a"), "a")
    XCTAssertEqual(AgentWallSelection.toggled(current: "a", hit: "a"), nil)
    XCTAssertEqual(AgentWallSelection.toggled(current: "a", hit: "b"), "b")
    XCTAssertEqual(AgentWallSelection.toggled(current: "a", hit: nil), nil)
    let agents = roster(["Henry"])
    XCTAssertEqual(AgentWallSelection.valid("henry", in: agents), "henry")
    XCTAssertNil(AgentWallSelection.valid("gone", in: agents))
    XCTAssertNil(AgentWallSelection.valid(nil, in: agents))
  }

  // MARK: Scroll

  func testReduceMotionStopsTheAutomaticScroll() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let scroll = AgentWallScroll(now: t0)
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(10)), 160, accuracy: 0.001, "16 points a second")
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(10), reduceMotion: true), 0)
    XCTAssertTrue(scroll.isMoving(reduceMotion: false))
    XCTAssertFalse(scroll.isMoving(reduceMotion: true), "the frame clock is paused")
  }

  func testHoverFreezesDragScrubsAndLeavingResumes() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var scroll = AgentWallScroll(now: t0)
    scroll.hoverMoved(at: t0.addingTimeInterval(5))
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(50)), 80, accuracy: 0.001, "frozen where the pointer arrived")
    scroll.dragChanged(translation: 30, at: t0.addingTimeInterval(51))
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(60)), 110, accuracy: 0.001)
    scroll.dragChanged(translation: -20, at: t0.addingTimeInterval(52))
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(60)), 60, accuracy: 0.001)
    scroll.dragEnded(at: t0.addingTimeInterval(53))
    XCTAssertFalse(scroll.isMoving(reduceMotion: false), "still hovering: stays frozen")
    scroll.hoverEnded(at: t0.addingTimeInterval(100))
    XCTAssertTrue(scroll.isMoving(reduceMotion: false))
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(110)), 60 + 160, accuracy: 0.001)
  }

  func testDragWithReduceMotionStillMovesTheWall() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var scroll = AgentWallScroll(now: t0)
    scroll.dragChanged(translation: 40, at: t0.addingTimeInterval(3), reduceMotion: true)
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(9), reduceMotion: true), 40, accuracy: 0.001)
    scroll.dragEnded(at: t0.addingTimeInterval(9))
    XCTAssertEqual(scroll.shift(at: t0.addingTimeInterval(99), reduceMotion: true), 40, accuracy: 0.001)
  }

  // MARK: Geometry (generic bricks)

  func testGeometryHitsTheBrickAndItsRepeats() {
    let plan = AgentWallPlan(agents: roster(["Atlas"]), showOffline: true)
    let g = AgentWallGeometry(plan: plan, width: 1200, wallHeight: 300, shift: 100)
    let tbd = plan.bricks[0]
    let rect = g.rects(of: tbd).first { $0.midX > 0 && $0.midX < 1200 }!
    XCTAssertEqual(g.brick(at: CGPoint(x: rect.midX, y: rect.midY))?.agentID, "tbd-default")
    XCTAssertNil(g.brick(at: CGPoint(x: rect.midX, y: AgentWallGeometry.calloutZone - 20)), "above the wall")
    let moved = AgentWallGeometry(plan: plan, width: 1200, wallHeight: 300, shift: 100 + g.loop)
    XCTAssertEqual(moved.brick(at: CGPoint(x: rect.midX, y: rect.midY))?.agentID, "tbd-default", "the wall repeats after one loop")
  }

  func testALongerBrickCoversEveryCellOfItsRun() {
    let brick = WallBrick(course: 4, startColumn: 3, length: 3, tone: .online, agentID: "x")
    XCTAssertEqual(Array(brick.columns), [3, 4, 5])
    XCTAssertEqual(WallBrick(course: 4, startColumn: 3, length: 0, tone: .online, agentID: "x").columns.count, 1)
  }

  func testCalloutsOnTheSameSideKeepTheirDistance() {
    let plan = AgentWallPlan(agents: roster(["Atlas", "Henry", "Nova", "Scribe"]), showOffline: true)
    let g = AgentWallGeometry(plan: plan, width: 1600, wallHeight: 300, shift: 100)
    let placed = g.placements(crowding: 160)
    XCTAssertFalse(placed.isEmpty)
    for side in [true, false] {
      let xs = placed.filter { $0.above == side }.map(\.rect.midX).sorted()
      for pair in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1 - pair.0, 160) }
    }
  }

  // MARK: No process

  static func sourceFolder(_ relative: String) -> String {
    let file = URL(fileURLWithPath: #filePath)  // .../Dayflow/DayflowTests/AgentWallTests.swift
    return file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Dayflow/\(relative)").path
  }

  func testTheAgentsCodePathStartsNoProcess() throws {
    let forbidden = ["Process(", "NSTask", "posix_spawn", "execv", "system(", "popen(", "NSAppleScript", "/bin/", "URLSession", "WKWebView"]
    var checked = 0
    for folder in ["Views/UI/Agents", "Core/Agents"] {
      let path = Self.sourceFolder(folder)
      let files = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".swift") }
      XCTAssertFalse(files.isEmpty, path)
      for file in files {
        let text = try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        // Comments may name the words; the code may not.
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
          .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for word in forbidden { XCTAssertFalse(code.contains(word), "\(folder)/\(file) uses \(word)") }
        checked += 1
      }
    }
    XCTAssertGreaterThanOrEqual(checked, 4)
  }

  func testTheOnlyHelperCallIsListAgents() throws {
    var calls = Set<String>()
    for folder in ["Views/UI/Agents", "Core/Agents"] {
      let path = Self.sourceFolder(folder)
      for file in try FileManager.default.contentsOfDirectory(atPath: path) where file.hasSuffix(".swift") {
        let text = try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        for match in text.components(separatedBy: "accountCall(\"").dropFirst() { calls.insert(String(match.prefix { $0 != "\"" })) }
      }
    }
    XCTAssertEqual(calls, ["listAgents"])
  }
}
