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

  func testAWorkspaceRowWithTheOwnIdIsDropped() {
    // After the own row, before the own row, with the default own id, and with a custom own id.
    let imposter = workspaceRow("tbd-default", "Imposter")
    XCTAssertEqual(AgentWallRoster.decode([ownRow, imposter, workspaceRow("a", "Henry")]).agents.map(\.name), ["TBD", "Henry"])
    XCTAssertEqual(AgentWallRoster.decode([imposter, ownRow, workspaceRow("a", "Henry")]).agents.map(\.name), ["TBD", "Henry"])
    XCTAssertEqual(AgentWallRoster.decode([imposter, workspaceRow("a", "Henry")]).agents.map(\.name), ["TBD", "Henry"])
    var custom = ownRow
    custom["id"] = "own-7"
    let result = AgentWallRoster.decode([workspaceRow("own-7", "Imposter"), custom, workspaceRow("a", "Henry")])
    XCTAssertEqual(result.agents.map(\.name), ["TBD", "Henry"])
    XCTAssertEqual(result.agents.map(\.id), ["own-7", "a"])
    XCTAssertEqual(result.agents.filter(\.own).count, 1)
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
    var book = AgentWallSlotBook()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    book.update(with: roster(["Atlas", "Nova"]), now: t0)
    let before = AgentWallPlan(agents: roster(["Atlas", "Nova"]), showOffline: true, slotOrder: book.order)
    // "Henry" sorts between Atlas and Nova, but it is new: it goes to the end and nobody moves.
    book.update(with: roster(["Atlas", "Henry", "Nova"]), now: t0.addingTimeInterval(60))
    let after = AgentWallPlan(agents: roster(["Atlas", "Henry", "Nova"]), showOffline: true, slotOrder: book.order)
    XCTAssertEqual(book.order, ["tbd-default", "atlas", "nova", "henry"])
    for brick in before.bricks { XCTAssertTrue(after.bricks.contains(brick), "\(brick.agentID) did not move") }
    XCTAssertEqual(after.bricks.count, before.bricks.count + 1)
    let henry = after.bricks.first { $0.agentID == "henry" }
    XCTAssertEqual(henry?.course, AgentWallPlan.slot(3).course)
    XCTAssertEqual(henry?.startColumn, AgentWallPlan.slot(3).column)
    // Without a stored order (first run) the slots follow the names.
    XCTAssertEqual(AgentWallPlan(agents: roster(["Atlas", "Henry", "Nova"]), showOffline: true).bricks.map(\.agentID), ["tbd-default", "atlas", "henry", "nova"])
  }

  func testSlotBookKeepsTheOrderPersistsItAndPrunesAfter30Days() {
    let suite = "tbd.test.wallslots.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    var book = AgentWallSlotBook(defaults: defaults)
    XCTAssertEqual(book.order, [])
    // Two new agents at once: name order. A workspace agent called "Aaa" never takes slot 0.
    book.update(with: roster(["Zed", "Aaa", "Beta"]), now: t0)
    XCTAssertEqual(book.order, ["tbd-default", "aaa", "beta", "zed"])
    book.save(to: defaults)
    XCTAssertEqual(defaults.array(forKey: "agentWallSlotOrder") as? [String], ["tbd-default", "aaa", "beta", "zed"])
    var again = AgentWallSlotBook(defaults: defaults)
    XCTAssertEqual(again, book)
    // "beta" leaves. It keeps its slot (a gap on the wall) and a new agent goes to the end, not into the gap.
    again.update(with: roster(["Aaa", "Zed", "Newbie"]), now: t0.addingTimeInterval(day))
    XCTAssertEqual(again.order, ["tbd-default", "aaa", "beta", "zed", "newbie"])
    let plan = AgentWallPlan(agents: roster(["Aaa", "Zed", "Newbie"]), showOffline: true, slotOrder: again.order)
    XCTAssertEqual(plan.bricks.first { $0.agentID == "zed" }?.startColumn, AgentWallPlan.slot(3).column)
    XCTAssertEqual(plan.bricks.first { $0.agentID == "newbie" }?.startColumn, AgentWallPlan.slot(4).column)
    // 29 days after it was last seen the slot is still held; after 31 days it is pruned and the later agents close up.
    again.update(with: roster(["Aaa", "Zed", "Newbie"]), now: t0.addingTimeInterval(29 * day))
    XCTAssertTrue(again.order.contains("beta"))
    again.update(with: roster(["Aaa", "Zed", "Newbie"]), now: t0.addingTimeInterval(31 * day))
    XCTAssertEqual(again.order, ["tbd-default", "aaa", "zed", "newbie"])
    XCTAssertNil(again.lastSeen["beta"])
    // An agent that returns after the prune is new again.
    again.update(with: roster(["Aaa", "Beta", "Zed", "Newbie"]), now: t0.addingTimeInterval(32 * day))
    XCTAssertEqual(again.order.last, "beta")
  }

  func testTBDIsSlotZeroWhateverTheStoredOrderSays() {
    let agents = roster(["Aaa", "Beta"])
    let plan = AgentWallPlan(agents: agents, showOffline: true, slotOrder: ["aaa", "tbd-default", "beta"])
    XCTAssertEqual(plan.bricks.first { $0.agentID == "tbd-default" }?.startColumn, AgentWallPlan.slot(0).column)
    XCTAssertEqual(Set(plan.bricks.map { "\($0.course)-\($0.startColumn)" }).count, 3)
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
    /// Answers handed out first, one per call; then `answer`.
    var queue: [Any] = []
    var failure = false
    var blocking = false
    private var gate: CheckedContinuation<Void, Never>?
    func listAgents() async throws -> Any {
      calls += 1
      if blocking { await withCheckedContinuation { gate = $0 } }
      if failure { throw CocoaError(.fileReadUnknown) }
      return queue.isEmpty ? answer : queue.removeFirst()
    }
    func release() { gate?.resume(); gate = nil; blocking = false }
  }

  /// A mutable account for the store under test.
  final class AccountBox {
    var key: AgentWallAccountKey
    init(_ key: AgentWallAccountKey = AgentWallAccountKey(signedIn: true, workspace: "w1", profile: "p1", issuer: "https://i1", email: "a@x.test")) {
      self.key = key
    }
  }

  private var suites: [String] = []

  override func tearDown() {
    for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    suites = []
    super.tearDown()
  }

  /// A store with its own UserDefaults suite (the slot order never touches the real defaults).
  private func makeStore(
    _ client: FakeClient, signedIn: Bool = true, active: Bool = true, account: AccountBox? = nil, defaults: UserDefaults? = nil
  ) -> AgentWallRosterStore {
    let suite = "tbd.test.wallstore.\(UUID().uuidString)"
    suites.append(suite)
    let store = defaults ?? UserDefaults(suiteName: suite)!
    if let account {
      return AgentWallRosterStore(client: client, account: { account.key }, isAppActive: { active }, slotDefaults: store)
    }
    return AgentWallRosterStore(client: client, signedIn: { signedIn }, isAppActive: { active }, slotDefaults: store)
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

  func testAWorkspaceSwitchWhileHiddenShowsNoOldNames() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let account = AccountBox()
    let store = makeStore(client, account: account)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Henry"])
    store.pageDidDisappear()
    // The workspace changes while the page is hidden. The next call is slow.
    account.key.workspace = "w2"
    client.blocking = true
    client.answer = [ownRow, workspaceRow("2", "Nova")]
    store.pageDidAppear()
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD"], "the old names are gone before the new call answers")
    XCTAssertFalse(store.state.loaded)
    XCTAssertNil(store.state.notice, "nothing is said before the first answer")
    await waitUntil("second call runs") { client.calls == 2 && store.isRefreshing }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD"])
    client.release()
    await waitUntil("new answer") { !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Nova"])
    // Every part of the account counts: profile, issuer, email.
    for change in [{ account.key.profile = "p2" }, { account.key.issuer = "https://i2" }, { account.key.email = "b@x.test" }] {
      change()
      store.accountDidChange()
      XCTAssertEqual(store.state.agents.map(\.name), ["TBD"], "reset at once")
      await waitUntil("answer") { !store.isRefreshing && store.state.loaded }
    }
    store.pageDidDisappear()
  }

  func testAnAccountChangeDuringACallDropsTheStaleAnswerAndReadsOnce() async {
    let client = FakeClient()
    client.blocking = true
    client.queue = [[ownRow, workspaceRow("1", "OldWorkspaceAgent")], [ownRow, workspaceRow("2", "NewWorkspaceAgent")]]
    let account = AccountBox()
    let store = makeStore(client, account: account)
    store.pageDidAppear()
    await waitUntil("first call runs") { client.calls == 1 && store.isRefreshing }
    account.key.workspace = "w2"
    store.accountDidChange()
    store.accountDidChange()
    client.release()
    await waitUntil("one retry") { client.calls == 2 && !store.isRefreshing && store.state.loaded }
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(client.calls, 2, "exactly one retry")
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "NewWorkspaceAgent"], "the answer of the old account was dropped")
    store.pageDidDisappear()
  }

  func testSigningOutWhileHiddenShowsTBDAndTheNoticeAtOnceAndMakesNoCall() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let account = AccountBox()
    let store = makeStore(client, account: account)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    store.pageDidDisappear()
    account.key = AgentWallAccountKey(signedIn: false)
    store.pageDidAppear()
    XCTAssertEqual(store.state.mode, .signedOut)
    XCTAssertEqual(store.state.agents, [.tbd], "no old names, not even for a moment")
    XCTAssertEqual(store.state.notice?.text, AgentWallNotice.signedOut.text)
    await waitUntil { store.state.loaded }
    XCTAssertEqual(client.calls, 1, "no call without an account")
    store.pageDidDisappear()
  }

  func testNoSignedOutFlashBeforeTheSessionIsChecked() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let account = AccountBox(AgentWallAccountKey(signedIn: false, checked: false))
    let store = makeStore(client, account: account)
    XCTAssertEqual(store.state.agents, [.tbd])
    XCTAssertNil(store.state.notice, "launch: no sign-in notice yet")
    store.pageDidAppear()
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertNil(store.state.notice)
    XCTAssertEqual(client.calls, 0)
    // The session check says signed in: the roster is read, still no notice on the way.
    account.key = AgentWallAccountKey(signedIn: true, checked: true, workspace: "w1")
    store.accountDidChange()
    XCTAssertNil(store.state.notice)
    await waitUntil("roster") { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Henry"])
    store.pageDidDisappear()
    // The session check says signed out: now the notice shows.
    let out = AccountBox(AgentWallAccountKey(signedIn: false, checked: false))
    let outStore = makeStore(FakeClient(), account: out)
    outStore.pageDidAppear()
    out.key = AgentWallAccountKey(signedIn: false, checked: true)
    outStore.accountDidChange()
    XCTAssertEqual(outStore.state.notice?.text, AgentWallNotice.signedOut.text)
    outStore.pageDidDisappear()
    XCTAssertNil(AgentWallState(signedIn: false, sessionChecked: false).notice)
    XCTAssertNotNil(AgentWallState(signedIn: false, sessionChecked: true).notice)
  }

  func testAFailureOnTheVeryFirstLoadShowsTBDAndTheNotice() async {
    let client = FakeClient()
    client.failure = true
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil("failed first read") { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.state.agents, [.tbd])
    XCTAssertEqual(store.state.mode, .empty)
    XCTAssertEqual(store.state.notice?.needsYou, true)
    XCTAssertTrue(store.state.notice?.text.contains("could not be loaded") == true)
    XCTAssertTrue(store.state.signedIn)
    // The next good answer replaces the notice.
    client.failure = false
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    store.visibleTimerFired()
    await waitUntil("next read") { client.calls == 2 && !store.isRefreshing }
    XCTAssertEqual(store.state.agents.map(\.name), ["TBD", "Henry"])
    XCTAssertNil(store.state.notice)
    store.pageDidDisappear()
  }

  func testAMinimisedOrHiddenWindowStopsTheTimerAndTheCalls() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("1", "Henry")]
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertTrue(store.isPolling)
    store.windowVisibilityChanged(false)
    XCTAssertFalse(store.isPolling, "no timer while the window is hidden")
    store.visibleTimerFired()
    store.appDidBecomeActive()
    await store.refresh()
    try? await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(client.calls, 1, "no call while the window is hidden")
    store.windowVisibilityChanged(true)
    XCTAssertTrue(store.isPolling)
    await waitUntil("read after the window is back") { client.calls == 2 && !store.isRefreshing }
    // A window that comes back while the page is not visible starts nothing.
    store.pageDidDisappear()
    store.windowVisibilityChanged(false)
    store.windowVisibilityChanged(true)
    XCTAssertFalse(store.isPolling)
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(client.calls, 2)
  }

  func testWindowVisibilityRule() {
    XCTAssertTrue(AgentWallWindowVisibility.isVisible(occlusion: [.visible], miniaturized: false))
    XCTAssertFalse(AgentWallWindowVisibility.isVisible(occlusion: [], miniaturized: false), "covered or hidden")
    XCTAssertFalse(AgentWallWindowVisibility.isVisible(occlusion: [.visible], miniaturized: true), "minimised")
  }

  func testTheRosterStoreWritesTheSlotOrderToItsOwnDefaults() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("b", "Beta"), workspaceRow("a", "Alpha")]
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.slotOrder, ["tbd-default", "a", "b"])
    // A new Henry does not move Alpha or Beta, even though he sorts between them.
    client.answer = [ownRow, workspaceRow("b", "Beta"), workspaceRow("h", "Aa Henry"), workspaceRow("a", "Alpha")]
    store.visibleTimerFired()
    await waitUntil("second read") { client.calls == 2 && !store.isRefreshing }
    XCTAssertEqual(store.slotOrder, ["tbd-default", "a", "b", "h"])
    store.pageDidDisappear()
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

  func testASelectionThatLeavesTheRosterIsCleared() async {
    let client = FakeClient()
    client.answer = [ownRow, workspaceRow("henry", "Henry"), workspaceRow("nova", "Nova")]
    let store = makeStore(client)
    store.pageDidAppear()
    await waitUntil { client.calls == 1 && !store.isRefreshing && store.state.loaded }
    var selected: String? = "henry"
    // What the page does on every change of the visible agents.
    func rosterChanged() { selected = AgentWallSelection.valid(selected, in: store.state.visible(showOffline: true)) }
    rosterChanged()
    XCTAssertEqual(selected, "henry")
    client.answer = [ownRow, workspaceRow("nova", "Nova")]
    store.visibleTimerFired()
    await waitUntil("henry left") { client.calls == 2 && !store.isRefreshing }
    rosterChanged()
    XCTAssertNil(selected)
    store.pageDidDisappear()
    let source = try? String(contentsOfFile: Self.sourceFolder("Views/UI/Agents") + "/AgentWallView.swift", encoding: .utf8)
    XCTAssertTrue(source?.contains(".onChange(of: agents)") == true && source?.contains("AgentWallSelection.valid(selectedID, in: now)") == true)
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

  func testCrowdingFollowsTheBrickPitch() {
    XCTAssertEqual(AgentWallGeometry.crowding(wallHeight: 360), 160)
    XCTAssertEqual(AgentWallGeometry.crowding(wallHeight: 150), 112.5, accuracy: 0.01)
    XCTAssertEqual(AgentWallGeometry.crowding(wallHeight: 100), 112, "never below 112")
    XCTAssertEqual(AgentWallGeometry.labelWidth(crowding: 160), 148)
  }

  func testNoTwoLabelsOfOneSideTouchWith20And100Agents() {
    for count in [20, 100] {
      let plan = AgentWallPlan(agents: roster((0..<count).map { String(format: "Agent %03d with a long name", $0) }), showOffline: true)
      for height in [150.0, 360.0] {
        let crowding = AgentWallGeometry.crowding(wallHeight: CGFloat(height))
        for width in [900.0, 1280.0, 1600.0] {
          for shift in stride(from: 0.0, to: 3_000.0, by: 113.0) {
            let g = AgentWallGeometry(plan: plan, width: CGFloat(width), wallHeight: CGFloat(height), shift: shift)
            let placed = g.placements(crowding: crowding)
            XCTAssertFalse(placed.isEmpty, "\(count) agents, height \(height)")
            XCTAssertEqual(Set(placed.map(\.id)).count, placed.count, "label ids are unique")
            for above in [true, false] {
              let frames = placed.filter { $0.above == above }.map(\.labelFrame)
              for (i, a) in frames.enumerated() {
                XCTAssertEqual(a.width, crowding - 12, accuracy: 0.001)
                for b in frames[(i + 1)...] {
                  XCTAssertFalse(a.intersects(b), "\(count) agents, height \(height), width \(width), shift \(shift): \(a) \(b)")
                }
              }
            }
          }
        }
      }
    }
  }

  func testTheListHintAppearsOnlyWhenSomeBricksCanLoseTheirLabel() {
    func hint(_ count: Int, _ height: CGFloat) -> Bool {
      let plan = AgentWallPlan(agents: roster((0..<count).map { String(format: "Agent %03d", $0) }), showOffline: true)
      return AgentWallGeometry(plan: plan, width: 1280, wallHeight: height, shift: 0).hasUnlabelledBricks(crowding: AgentWallGeometry.crowding(wallHeight: height))
    }
    XCTAssertTrue(hint(100, 150))
    XCTAssertTrue(hint(20, 150), "a small wall: the nearest same-side bricks are 84 pt apart, a label needs 112")
    XCTAssertFalse(hint(100, 360), "a tall wall: the nearest same-side bricks are 202 pt apart, a label needs 160")
    XCTAssertFalse(hint(20, 360))
    XCTAssertFalse(hint(1, 150), "TBD alone")
    XCTAssertEqual(AgentWallView.namesOnlyInListHint, "Some names are only in this list.")
  }

  func testLabelIdsKeepTheirCopyWhileTheWallScrolls() {
    let plan = AgentWallPlan(agents: roster(["Atlas"]), showOffline: true)
    func ids(_ shift: Double) -> Set<String> {
      Set(AgentWallGeometry(plan: plan, width: 3_000, wallHeight: 150, shift: shift).placements(crowding: 112).map(\.id))
    }
    let a = ids(100), b = ids(103)
    XCTAssertFalse(a.isEmpty)
    XCTAssertEqual(a, b, "a small scroll keeps the same label identities")
    XCTAssertTrue(a.allSatisfy { $0.contains("#") })
  }

  func testCalloutTextIsCutToFit() {
    XCTAssertEqual(AgentWallLabelText.truncated("short", limit: 20), "short")
    XCTAssertEqual(AgentWallLabelText.truncated("exactly twenty chars", limit: 20), "exactly twenty chars")
    let cut = AgentWallLabelText.truncated("A very long harness label that never ends", limit: 20)
    XCTAssertEqual(cut.count, 20)
    XCTAssertTrue(cut.hasSuffix("…"))
    XCTAssertEqual(AgentWallLabelText.title(String(repeating: "x", count: 50)).count, 34)
    XCTAssertEqual(AgentWallLabelText.metaLines("Codex\npaused"), ["Codex", "paused"])
    XCTAssertEqual(AgentWallLabelText.metaLines("online"), ["online"])
    XCTAssertEqual(AgentWallLabelText.metaLines("Claude Agent SDK with extras\nonline").first?.count, 20)
    // The placement carries the cut lines and a label frame of crowding - 12.
    let long = AgentWallRoster.decode([ownRow, workspaceRow("1", "Henry", harness: "A harness with a really long name")]).agents
    let plan = AgentWallPlan(agents: long, showOffline: true)
    let placed = AgentWallGeometry(plan: plan, width: 1600, wallHeight: 300, shift: 100).placements(crowding: 160)
    XCTAssertTrue(placed.allSatisfy { $0.metaLines.allSatisfy { $0.count <= 20 } })
    XCTAssertTrue(placed.allSatisfy { $0.labelFrame.width == 148 })
  }

  func testTheHoverCardStaysInsideTheBand() {
    XCTAssertEqual(AgentWallView.hoverCardX(pointX: 10, width: 1000), 26)
    XCTAssertEqual(AgentWallView.hoverCardX(pointX: 990, width: 1000), 720)
    XCTAssertEqual(AgentWallView.hoverCardX(pointX: 5, width: 200), 0, "a narrow band never pushes the card left of 0")
    XCTAssertEqual(AgentWallView.hoverCardX(pointX: -30, width: 1000), 0)
  }

  func testTheWallBandHasOneAccessibilityLabelThatCountsTheAgents() {
    let s = state([ownRow, workspaceRow("1", "A"), workspaceRow("2", "B", state: "paused"), workspaceRow("3", "C", state: "offline"), workspaceRow("4", "D", state: "offline")])
    XCTAssertEqual(s.wallLabel, "Agents wall: 5 agents, 2 online, 1 paused, 2 offline.")
    XCTAssertEqual(state([ownRow]).wallLabel, "Agents wall: 1 agent, 1 online, 0 paused, 0 offline.")
    let source = try? String(contentsOfFile: Self.sourceFolder("Views/UI/Agents") + "/AgentWallView.swift", encoding: .utf8)
    XCTAssertTrue(source?.contains(".accessibilityElement(children: .ignore)") == true)
    XCTAssertTrue(source?.contains(".accessibilityLabel(label)") == true)
  }

  func testTheWallPhotosAreDecodedOnce() {
    let cache = AgentWallPhotoCache.shared
    for photo in AgentWallPhoto.allCases {
      guard let first = cache.cgImage(photo) else { return XCTFail("\(photo.assetName) is not in the asset catalog") }
      XCTAssertTrue(first === cache.cgImage(photo), "the same decoded image every frame")
    }
    // The band's draw code resolves from the cache, not from the asset name per frame.
    let band = try? String(contentsOfFile: Self.sourceFolder("Views/UI/Agents") + "/AgentWallBand.swift", encoding: .utf8)
    XCTAssertTrue(band?.contains("context.resolve(cache.image(") == true)
    XCTAssertFalse(band?.contains("context.resolve(Image(") == true)
    let view = try? String(contentsOfFile: Self.sourceFolder("Views/UI/Agents") + "/AgentWallView.swift", encoding: .utf8)
    XCTAssertTrue(view?.contains("minimumInterval: 1.0 / 30") == true, "30 frames a second")
  }

  // MARK: No process

  static func sourceFolder(_ relative: String) -> String {
    let file = URL(fileURLWithPath: #filePath)  // .../Dayflow/DayflowTests/AgentWallTests.swift
    return file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Dayflow/\(relative)").path
  }

  /// The code of every Swift file of the Agents path, comments cut away.
  private func agentsCode() throws -> [(file: String, code: String)] {
    var out: [(String, String)] = []
    for folder in ["Views/UI/Agents", "Core/Agents"] {
      let path = Self.sourceFolder(folder)
      let files = try FileManager.default.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".swift") }
      XCTAssertFalse(files.isEmpty, path)
      for file in files {
        let text = try String(contentsOfFile: path + "/" + file, encoding: .utf8)
        // Comments may name the words; the code may not. Cut `// ...` to the end of the line (also after code).
        let code = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
          guard let range = line.range(of: "//") else { return String(line) }
          return String(line[line.startIndex..<range.lowerBound])
        }.joined(separator: "\n")
        out.append(("\(folder)/\(file)", code))
      }
    }
    return out
  }

  func testTheAgentsCodePathStartsNoProcess() throws {
    let files = try agentsCode()
    XCTAssertGreaterThanOrEqual(files.count, 4)
    // Whole words only (so `ProcessInfo` and `nodeCount` do not match), `system(` as a call, `/bin/sh` as a path.
    let tokens = try NSRegularExpression(pattern: "\\b(Process|NSTask|posix_spawn|execv|execve|popen|npx|node|zsh|sh|bash)\\b|\\bsystem\\s*\\(|/bin/|NSAppleScript|URLSession|WKWebView")
    for (file, code) in files {
      let range = NSRange(code.startIndex..., in: code)
      let hits = tokens.matches(in: code, range: range).compactMap { Range($0.range, in: code).map { String(code[$0]) } }
      XCTAssertTrue(hits.isEmpty, "\(file) uses \(hits)")
    }
    // The scanner itself catches what it must.
    for bad in ["let p = Process()", "NSTask.launch", "posix_spawn(&pid)", "system(\"x\")", "npx tbd", "node x.js", "/bin/sh -c", "zsh -l"] {
      XCTAssertNotNil(tokens.firstMatch(in: bad, range: NSRange(bad.startIndex..., in: bad)), bad)
    }
    for fine in ["ProcessInfo.processInfo", "nodeCount", "let shift = 1", "systematic"] {
      XCTAssertNil(tokens.firstMatch(in: fine, range: NSRange(fine.startIndex..., in: fine)), fine)
    }
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
