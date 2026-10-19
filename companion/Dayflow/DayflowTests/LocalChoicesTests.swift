import XCTest
import TBDModels

@testable import TBD

/// A helper that never leaves the process: no Keychain, no network, no relay. It records every call.
@MainActor
final class FakeLocalChoicesClient: LocalChoicesClient {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  var rules: [TBDLocalChoice] = []
  var unreadable = false
  var listError: Error?
  var revokeError: Error?
  private(set) var listCalls = 0
  private(set) var revokeCalls: [String] = []
  /// While true, `choices()` answers with the list it had when it started, after the test resumes `waiter`.
  var hold = false
  var waiter: CheckedContinuation<Void, Never>?

  func choices() async throws -> TBDLocalChoices {
    listCalls += 1
    if let listError { throw listError }
    let snapshot = rules
    if hold { await withCheckedContinuation { waiter = $0 } }
    return TBDLocalChoices(choices: snapshot, unreadable: unreadable)
  }

  func revoke(key: String) async throws -> TBDLocalChoices {
    revokeCalls.append(key)
    if let revokeError { throw revokeError }
    rules.removeAll { $0.key == key }
    return TBDLocalChoices(choices: rules, unreadable: unreadable)
  }
}

/// Settings › Access, "Your choices for TBD's agent on this Mac" (dev.17, C13 local): the list, Remove, and the failure sentences.
@MainActor
final class LocalChoicesTests: XCTestCase {
  private var fake: FakeLocalChoicesClient!

  override func setUp() async throws { fake = FakeLocalChoicesClient() }

  private let test = TBDLocalChoice(key: "shell:npm test", decision: .always)
  private let write = TBDLocalChoice(key: "write:/Users/me/Projects/x", decision: .never)
  private let web = TBDLocalChoice(key: "web:example.com", decision: .always)

  private func makeStore() -> LocalChoicesStore { LocalChoicesStore(client: fake) }

  private func waitUntil(_ what: String = "", _ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    XCTAssertTrue(condition(), what)
  }

  func testTheListShowsTheHelpersChoicesWhenThePaneAppears() async {
    fake.rules = [test, write, web]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("loaded") { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.choices, [test, write, web])
    XCTAssertNil(store.state.issue)
    XCTAssertEqual(fake.listCalls, 1)
  }

  func testNoCallWhileThePaneOrItsWindowIsNotVisible() async {
    let store = makeStore()
    await store.refresh()
    XCTAssertEqual(fake.listCalls, 0, "the pane never appeared")
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    store.windowVisibilityChanged(false)
    store.appDidBecomeActive()
    await store.refresh()
    XCTAssertEqual(fake.listCalls, 1, "a hidden window asks nothing")
    store.pageDidDisappear()
    store.windowVisibilityChanged(true)
    await store.refresh()
    XCTAssertEqual(fake.listCalls, 1)
  }

  func testNoOverlap() async {
    fake.rules = [test]
    fake.hold = true
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("in flight") { store.isRefreshing }
    await store.refresh()
    await store.refresh()
    XCTAssertEqual(fake.listCalls, 1, "a refresh that is running is not started again")
    fake.waiter?.resume()
    await waitUntil { store.state.loaded && !store.isRefreshing }
  }

  func testRemoveCallsRevokeWithTheKeyAndShowsWhatIsLeft() async {
    fake.rules = [test, write]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    let ok = await store.remove(test)
    XCTAssertTrue(ok)
    XCTAssertEqual(fake.revokeCalls, ["shell:npm test"])
    XCTAssertEqual(store.state.choices, [write])
    XCTAssertFalse(store.removeFailed)
  }

  func testAFailedRemoveSaysSoAndKeepsTheList() async {
    fake.rules = [test, write]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    fake.revokeError = FakeLocalChoicesClient.Failure(message: "boom")
    let ok = await store.remove(test)
    XCTAssertFalse(ok)
    XCTAssertTrue(store.removeFailed)
    XCTAssertEqual(store.state.choices, [test, write], "the choice is still there")
    XCTAssertEqual(TBDLocalChoices.removeFailedLine, "TBD could not forget that choice. Try again.")
    // the next try works and clears the sentence
    fake.revokeError = nil
    let retried = await store.remove(test)
    XCTAssertTrue(retried)
    XCTAssertFalse(store.removeFailed)
    XCTAssertEqual(store.state.choices, [write])
  }

  func testARefreshThatStartedBeforeARemoveDoesNotBringTheChoiceBack() async {
    fake.rules = [test, write]
    fake.hold = true
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil("in flight") { store.isRefreshing }
    fake.hold = false
    let removed = await store.remove(test)
    XCTAssertTrue(removed)
    fake.waiter?.resume()  // the old call answers with the list from before the remove
    await waitUntil { !store.isRefreshing }
    XCTAssertEqual(store.state.choices, [write], "the forgotten choice stays forgotten")
  }

  func testAFailedReadKeepsTheLastListAndSaysSoNeverNoChoices() async {
    fake.rules = [test]
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    fake.listError = FakeLocalChoicesClient.Failure(message: "timeout")
    await store.refresh()
    XCTAssertEqual(store.state.issue, .failed)
    XCTAssertEqual(store.state.choices, [test], "the last good list stays")
    XCTAssertEqual(TBDLocalChoices.line(.failed), "TBD could not read your choices for this Mac.")
    // a first read that fails: no list, the failure sentence, and the view must not say "no choices"
    let first = makeStore()
    first.pageDidAppear()
    await waitUntil { first.state.loaded && !first.isRefreshing }
    XCTAssertEqual(first.state.issue, .failed)
    XCTAssertTrue(first.state.choices.isEmpty)
    // and a good read clears it
    fake.listError = nil
    await store.refresh()
    XCTAssertNil(store.state.issue)
  }

  func testAnUnreadableFileSaysItKeptACopy() async {
    fake.unreadable = true
    let store = makeStore()
    store.pageDidAppear()
    await waitUntil { store.state.loaded && !store.isRefreshing }
    XCTAssertEqual(store.state.issue, .unreadable)
    XCTAssertEqual(TBDLocalChoices.line(.unreadable), "TBD could not read your choices for this Mac. It kept a copy.")
  }

  func testTheWordsOfTheSection() {
    XCTAssertEqual(TBDLocalChoices.title, "Your choices for TBD's agent on this Mac")
    XCTAssertEqual(TBDLocalChoices.connectorsLine, "Choices for connected accounts are in Settings › Connectors.")
    XCTAssertEqual(TBDLocalChoices.note, "These are TBD's own permissions on this Mac. They are not Rules rules (that needs Rules).")
  }

  func testASeededStoreAsksNothing() async {
    let store = makeStore()
    store.seed(LocalChoicesState(choices: [test], issue: nil, loaded: true))
    store.pageDidAppear()
    await store.refresh()
    XCTAssertEqual(fake.listCalls, 0)
    let removed = await store.remove(test)
    XCTAssertFalse(removed)
    XCTAssertEqual(fake.revokeCalls, [])
    XCTAssertEqual(store.state.choices, [test])
  }
}
