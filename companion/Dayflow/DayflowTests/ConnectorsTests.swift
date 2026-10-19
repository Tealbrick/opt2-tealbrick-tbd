import XCTest
import TBDModels

@testable import TBD

/// A Connectors helper that never leaves the process: no Keychain, no network, no relay. It records every call.
@MainActor
final class FakeConnectorsClient: ConnectorsClient {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  var accessValue: TBDAppAccess = .unlocked
  var connected = true
  var accountsResult: Result<TBDConnectorAccounts, Error> = .success(TBDConnectorAccounts(available: true))
  var rules: [TBDConnectorChoice] = []
  private(set) var accessCalls = 0
  private(set) var connectionCalls = 0
  private(set) var accountCalls = 0
  private(set) var choiceCalls = 0
  private(set) var revokeCalls: [(account: String, tool: String)] = []
  /// While true, `accounts()` waits (a pending call) until the test resumes `accountsWaiter`.
  var holdAccounts = false
  var accountsWaiter: CheckedContinuation<Void, Never>?
  /// While true, `choices()` waits until the test resumes `choicesWaiter`.
  var holdChoices = false
  var choicesWaiter: CheckedContinuation<Void, Never>?

  func access() async -> TBDAppAccess { accessCalls += 1; return accessValue }
  func agentConnected() async -> Bool { connectionCalls += 1; return connected }
  func accounts() async throws -> TBDConnectorAccounts {
    accountCalls += 1
    if holdAccounts { await withCheckedContinuation { accountsWaiter = $0 } }
    return try accountsResult.get()
  }
  func choices() async throws -> [TBDConnectorChoice] {
    choiceCalls += 1
    let snapshot = rules
    if holdChoices { await withCheckedContinuation { choicesWaiter = $0 } }
    return snapshot
  }
  func revoke(account: String, tool: String) async throws -> [TBDConnectorChoice] {
    revokeCalls.append((account, tool))
    rules.removeAll { $0.account == account && $0.tool == tool }
    return rules
  }
}

/// Settings › Connectors (C280 C11): the gate through the store, the refresh rules, the remembered choices.
@MainActor
final class ConnectorsTests: XCTestCase {
  private final class AccountBox {
    var key: AgentWallAccountKey
    init(_ key: AgentWallAccountKey) { self.key = key }
  }

  private var fake: FakeConnectorsClient!
  private var account: AccountBox!

  override func setUp() async throws {
    fake = FakeConnectorsClient()
    account = AccountBox(AgentWallAccountKey(signedIn: true, checked: true, workspace: "w1", profile: "p", issuer: "https://portal.example", email: "a@example.com"))
  }

  private let gmail = TBDConnectorAccount(id: "a1", label: "Work inbox", service: "gmail", kind: .asMe, access: .readUpdate)
  private let slack = TBDConnectorAccount(id: "a2", label: "Team Slack", service: "slack", kind: .asItself, access: .read)
  private let send = TBDConnectorChoice(account: "Work inbox", tool: "GMAIL_SEND_EMAIL", decision: .always)
  private let del = TBDConnectorChoice(account: "Team Slack", tool: "SLACK_DELETE", decision: .never)

  private func makeStore(active: Bool = true) -> ConnectorsStore {
    ConnectorsStore(client: fake, account: { [account] in account!.key }, isAppActive: { active })
  }

  private func waitUntil(_ what: String = "", _ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(condition(), what)
  }

  private func answer(_ accounts: [TBDConnectorAccount]) {
    fake.accountsResult = .success(TBDConnectorAccounts(available: true, accounts: accounts))
  }

  // MARK: Gate (plan × connection × grant)

  func testGateDecisionTableThroughTheStore() async {
    let grants: [(String, Result<TBDConnectorAccounts, Error>, TBDConnectorsGate?)] = [
      ("available", .success(TBDConnectorAccounts(available: true, accounts: [gmail])), .active),
      ("no grant", .success(TBDConnectorAccounts(available: false, reason: "no grant sentence")), .noGrant("no grant sentence")),
      ("failed", .failure(FakeConnectorsClient.Failure(message: "Connect did not answer in time. Try again.")), .failed("Connect did not answer in time. Try again.")),
    ]
    for access in [TBDAppAccess.unlocked, .install, .locked, .unknown] {
      for connected in [false, true] {
        for (name, result, expectedWhenAsked) in grants {
          fake = FakeConnectorsClient()
          fake.accessValue = access
          fake.connected = connected
          fake.accountsResult = result
          let store = makeStore()
          store.pageDidAppear()
          await waitUntil("\(access) \(connected) \(name)") { store.state.loaded && !store.isRefreshing }
          let state = store.state
          switch access {
          case .locked:
            XCTAssertEqual(state.gate, .locked)
            XCTAssertEqual(fake.connectionCalls, 0, "a locked Connect asks nothing more")
            XCTAssertEqual(fake.accountCalls, 0)
          case .install:
            XCTAssertEqual(state.gate, .install)
            XCTAssertEqual(fake.accountCalls, 0)
          case .unlocked, .unknown:
            if !connected {
              XCTAssertEqual(state.gate, .notConnected, "\(access) not connected")
              XCTAssertEqual(fake.accountCalls, 0, "no relay call for an agent that is not connected")
            } else {
              XCTAssertEqual(state.gate, expectedWhenAsked, "\(access) \(name)")
              XCTAssertEqual(fake.accountCalls, 1, "unknown is asked like unlocked: it never locks")
            }
          }
          if state.gate != .active { XCTAssertTrue(state.accounts.isEmpty, "no names unless the gate is active") }
          store.pageDidDisappear()
        }
      }
    }
  }

  func testAnUnknownPlanWithAWorkingGrantIsActive() async {
    fake.accessValue = .unknown
    answer([gmail])
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.gate, .active)
    XCTAssertEqual(store.state.accounts, [gmail])
    store.pageDidDisappear()
  }

  func testTheFirstStateIsCheckingNeverALock() {
    let store = makeStore()
    XCTAssertEqual(store.state.gate, .checking)
    XCTAssertEqual(store.state.gate.message, "Checking Connect…")
    XCTAssertEqual(fake.accessCalls, 0)
  }

  func testSignedOutAsksNothing() async {
    account.key = AgentWallAccountKey(signedIn: false, checked: true)
    let store = makeStore()
    store.pageDidAppear()
    XCTAssertEqual(store.state.gate, .signedOut)
    await store.refresh()
    XCTAssertEqual(fake.accessCalls + fake.connectionCalls + fake.accountCalls + fake.choiceCalls, 0)
    store.pageDidDisappear()
  }

  // MARK: What the pane lists

  func testListsAccountsAndRememberedChoices() async {
    answer([gmail, slack])
    fake.rules = [send, del]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.accounts.map(\.label), ["Work inbox", "Team Slack"])
    XCTAssertEqual(store.state.accounts.map(\.access.words), ["Read + create + update", "Read"])
    XCTAssertEqual(store.state.choices.map(\.text), ["Always allow · GMAIL_SEND_EMAIL · Work inbox", "Never allow · SLACK_DELETE · Team Slack"])
    XCTAssertEqual(fake.choiceCalls, 1)
    store.pageDidDisappear()
  }

  func testEmptyAccountsIsAnActiveGateWithAnEmptyList() async {
    answer([])
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.gate, .active)
    XCTAssertEqual(store.state.accounts, [])
    XCTAssertFalse(TBDConnectors.showsReadOnlyHint(store.state.accounts))
    store.pageDidDisappear()
  }

  func testAccessWordsAndTheReadOnlyHintRule() {
    XCTAssertEqual(
      [TBDConnectorAccess.read, .readUpdate, .readUpdateDelete].map(\.words), ["Read", "Read + create + update", "Full (+ delete)"])
    XCTAssertEqual([TBDConnectorKind.asMe, .asItself].map(\.words), ["as you", "as TBD"])
    XCTAssertTrue(TBDConnectors.showsReadOnlyHint([slack]))
    XCTAssertFalse(TBDConnectors.showsReadOnlyHint([slack, gmail]), "one account that can send: no hint")
    XCTAssertFalse(TBDConnectors.showsReadOnlyHint([]))
  }

  func testTheConnectLinksUseTheActiveIssuerAndWorkspace() {
    var issuer = "https://portal.example/"
    var workspace = "w1"
    let portal = ConnectorsPortal(issuer: { issuer }, workspace: { workspace })
    XCTAssertEqual(portal.connectLink(newAccount: false)?.absoluteString, "https://portal.example/w/w1/open?product=connect&path=/configure#agents")
    XCTAssertEqual(portal.connectLink(newAccount: true)?.absoluteString, "https://portal.example/w/w1/open?product=connect&path=/")
    XCTAssertEqual(portal.portalURL.absoluteString, "https://portal.example")
    workspace = "w2"
    issuer = "https://dev.example"
    XCTAssertEqual(portal.connectLink(newAccount: false)?.absoluteString, "https://dev.example/w/w2/open?product=connect&path=/configure#agents")
    workspace = ""
    XCTAssertNil(portal.connectLink(newAccount: false), "no workspace, no link")
  }

  // MARK: Refresh rules

  func testNoCallWhileThePaneIsNotVisible() async {
    let store = makeStore()
    await store.refresh()
    store.appDidBecomeActive()
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(fake.accessCalls, 0)
    XCTAssertFalse(store.isPolling)
  }

  func testAppearReadsOnceAndStartsTheFiveMinuteTimerAndDisappearStopsBoth() async {
    answer([gmail])
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("first read") { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(fake.accountCalls, 1)
    XCTAssertTrue(store.isPolling)
    XCTAssertEqual(ConnectorsStore.interval, 300)
    store.pageDidDisappear()
    XCTAssertFalse(store.isPolling)
    store.appDidBecomeActive()
    store.visibleTimerFired()
    await store.refresh()
    try? await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(fake.accountCalls, 1, "no call after the pane left")
  }

  func testTheTimerDoesNotReadInABackgroundApp() async {
    answer([gmail])
    let store = makeStore(active: false)
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    store.visibleTimerFired()
    try? await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(fake.accountCalls, 1)
    store.pageDidDisappear()
  }

  func testAHiddenWindowStopsTheTimerAndTheCalls() async {
    answer([gmail])
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertTrue(store.isPolling)
    store.windowVisibilityChanged(false)
    XCTAssertFalse(store.isPolling)
    store.visibleTimerFired()
    store.appDidBecomeActive()
    await store.refresh()
    try? await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(fake.accountCalls, 1, "no call while the window is hidden")
    store.windowVisibilityChanged(true)
    await waitUntil("read after the window is back") { self.fake.accountCalls == 2 && !store.isRefreshing }
    store.pageDidDisappear()
    store.windowVisibilityChanged(false)
    store.windowVisibilityChanged(true)
    XCTAssertFalse(store.isPolling, "a window that comes back while the pane is not visible starts nothing")
  }

  func testNoOverlappingRefresh() async {
    answer([gmail])
    fake.holdAccounts = true
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("pending call") { self.fake.accountsWaiter != nil }
    XCTAssertTrue(store.isRefreshing)
    // Everything that would refresh now is ignored.
    store.appDidBecomeActive()
    store.visibleTimerFired()
    await store.refresh()
    await store.refresh()
    XCTAssertEqual(fake.accountCalls, 1, "one call at a time")
    fake.holdAccounts = false
    fake.accountsWaiter?.resume()
    fake.accountsWaiter = nil
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.accounts, [gmail])
    XCTAssertEqual(fake.accountCalls, 1)
    store.pageDidDisappear()
  }

  func testAnAccountChangeClearsTheListBeforeTheNewAnswer() async {
    answer([gmail, slack])
    fake.rules = [send]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.accounts.count, 2)
    // The workspace changes; the new answer is pending.
    fake.holdAccounts = true
    fake.rules = []
    answer([])
    account.key.workspace = "w2"
    store.accountDidChange()
    XCTAssertEqual(store.state.gate, .checking, "back to checking at once")
    XCTAssertEqual(store.state.accounts, [], "no old names while the new call runs")
    XCTAssertEqual(store.state.choices, [], "no old choices either")
    await waitUntil("new call") { self.fake.accountsWaiter != nil }
    XCTAssertEqual(store.state.accounts, [])
    fake.holdAccounts = false
    fake.accountsWaiter?.resume()
    fake.accountsWaiter = nil
    await waitUntil("new answer") { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.gate, .active)
    XCTAssertEqual(store.state.accounts, [])
    XCTAssertEqual(store.state.choices, [])
    store.pageDidDisappear()
  }

  func testAnAnswerThatArrivesAfterAnAccountChangeIsDropped() async {
    answer([gmail])
    fake.holdAccounts = true
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("pending call") { self.fake.accountsWaiter != nil }
    // The account changes while the first call runs; its answer belongs to the old workspace.
    account.key.workspace = "w2"
    store.accountDidChange()
    answer([slack])
    fake.holdAccounts = false
    fake.accountsWaiter?.resume()
    fake.accountsWaiter = nil
    await waitUntil("answer of the new account") { self.fake.accountCalls >= 2 && !store.isRefreshing && store.state.loaded }
    XCTAssertEqual(store.state.accounts, [slack], "the old workspace's names never show")
    store.pageDidDisappear()
  }

  func testSigningOutClearsTheListWithoutACall() async {
    answer([gmail])
    fake.rules = [send]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    let calls = fake.accountCalls
    account.key = AgentWallAccountKey(signedIn: false, checked: true)
    store.accountDidChange()
    XCTAssertEqual(store.state.gate, .signedOut)
    XCTAssertEqual(store.state.accounts, [])
    XCTAssertEqual(store.state.choices, [])
    try? await Task.sleep(nanoseconds: 40_000_000)
    XCTAssertEqual(fake.accountCalls, calls)
    store.pageDidDisappear()
  }

  func testAFailedRefreshKeepsTheListAndSaysWhy() async {
    answer([gmail])
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    fake.accountsResult = .failure(FakeConnectorsClient.Failure(message: "Connect did not answer in time. Try again."))
    store.visibleTimerFired()
    await waitUntil("failed read") { self.fake.accountCalls == 2 && !store.isRefreshing }
    XCTAssertEqual(store.state.gate, .active)
    XCTAssertEqual(store.state.accounts, [gmail])
    XCTAssertEqual(store.state.notice, "Connect did not answer in time. Try again.")
    // The next good answer clears the notice.
    answer([gmail, slack])
    store.visibleTimerFired()
    await waitUntil("good read") { self.fake.accountCalls == 3 && !store.isRefreshing }
    XCTAssertNil(store.state.notice)
    XCTAssertEqual(store.state.accounts.count, 2)
    store.pageDidDisappear()
  }

  func testAFailureOnTheFirstReadIsTheGateLine() async {
    fake.accountsResult = .failure(FakeConnectorsClient.Failure(message: "The owner paused TBD's agent. Ask the owner to resume it in Portal."))
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.gate, .failed("The owner paused TBD's agent. Ask the owner to resume it in Portal."))
    store.pageDidDisappear()
  }

  // MARK: Remembered choices

  func testRemoveCallsRevokeWithTheAccountAndToolAndShowsWhatIsLeft() async {
    answer([gmail])
    fake.rules = [send, del]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    let ok = await store.remove(send)
    XCTAssertTrue(ok)
    XCTAssertEqual(fake.revokeCalls.count, 1)
    XCTAssertEqual(fake.revokeCalls.first?.account, "Work inbox")
    XCTAssertEqual(fake.revokeCalls.first?.tool, "GMAIL_SEND_EMAIL")
    XCTAssertEqual(store.state.choices, [del])
    let again = await store.remove(del)
    XCTAssertTrue(again)
    XCTAssertEqual(store.state.choices, [])
    XCTAssertEqual(fake.accountCalls, 1, "removing a local choice makes no Connect call")
    store.pageDidDisappear()
  }

  func testARefreshThatStartedBeforeARemoveDoesNotBringTheChoiceBack() async {
    answer([gmail])
    fake.rules = [send]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    // A second refresh reads the list (still with the choice) and waits; the person removes it meanwhile.
    fake.holdChoices = true
    store.appDidBecomeActive()
    await waitUntil("pending choices read") { self.fake.choicesWaiter != nil }
    _ = await store.remove(send)
    XCTAssertEqual(store.state.choices, [])
    fake.holdChoices = false
    fake.choicesWaiter?.resume()
    fake.choicesWaiter = nil
    await waitUntil { !store.isRefreshing }
    XCTAssertEqual(store.state.choices, [], "the forgotten choice stays forgotten")
    store.pageDidDisappear()
  }

  func testAFrozenStoreMakesNoCallAndKeepsItsSeed() async {
    let store = makeStore()
    store.seed(ConnectorsState(gate: .active, accounts: [gmail], choices: [send], loaded: true))
    store.pageDidAppear()
    await store.refresh()
    let removed = await store.remove(send)
    XCTAssertFalse(removed)
    try? await Task.sleep(nanoseconds: 30_000_000)
    XCTAssertEqual(fake.accessCalls + fake.accountCalls + fake.choiceCalls + fake.revokeCalls.count, 0)
    XCTAssertFalse(store.isPolling)
    XCTAssertEqual(store.state.accounts, [gmail])
    store.pageDidDisappear()
  }

  // MARK: Native allow-list

  func testTheChatChannelsForConnectorsAreAllowedWithTimeouts() {
    // The relay read can take the helper's worst case (open, initialize, list, call: 30 s each); the local file reads cannot.
    XCTAssertEqual(TBDChatRuntime.accountCallTimeoutSeconds("connectAccounts"), 140)
    XCTAssertEqual(TBDChatRuntime.accountCallTimeoutSeconds("connectConsentList"), 45)
    XCTAssertEqual(TBDChatRuntime.accountCallTimeoutSeconds("connectConsentRevoke"), 45)
  }
}
