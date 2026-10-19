import XCTest
import TBDModels

@testable import TBD

/// A connection recorder: a URLProtocol on the model client's own session. It answers every request itself (an OpenAI-style
/// reply, "off plan"), so no packet leaves the machine, and it keeps every request it saw, with its body.
final class FlowEgressRecorder: URLProtocol {
  nonisolated(unsafe) private static var recorded: [(url: URL, body: String)] = []
  private static let lock = NSLock()

  static func reset() { lock.lock(); recorded = []; lock.unlock() }
  static var requests: [(url: URL, body: String)] { lock.lock(); defer { lock.unlock() }; return recorded }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FlowEgressRecorder.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(buffer, count: n)
      }
    }
    Self.lock.lock()
    Self.recorded.append((request.url ?? URL(fileURLWithPath: "/"), String(decoding: body, as: UTF8.self)))
    Self.lock.unlock()
    let reply = try! JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": #"{"label":"on_plan","task":"g1"}"#]]]
    ])
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: reply)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

/// Egress proofs for the card labeller in cloud mode (review 1, 2): with the observer switch off nothing reaches the
/// connection; with the guard open the recorder does see the calls (so the recorder works); a card outside the plan never
/// appears in any request body.
@MainActor
final class FlowCardLabellerEgressTests: FlowObserverTestCase {
  private let day = "2026-10-05"
  private var store: TBDFlowStore!

  override func setUp() async throws {
    try await super.setUp()
    FlowEgressRecorder.reset()
    clock.set("2026-10-05T14:00:00Z")
    store = makeStore()
    // The plan runs 08:00 to 11:30.
    try store.addTask(title: "Write PLANTITLE-MARKER report", day: day, startAt: at("08:00:00Z"), endAt: at("11:00:00Z"))
    try store.addTask(title: "Answer email", day: day, startAt: at("08:00:00Z"), endAt: at("11:30:00Z"))
    // Cloud mode: a saved non-local connection, and the person's choice recorded.
    let connection = TBDModelConnection(name: "Cloud", endpoint: "https://llm.example.test/v1", kind: .openAICompatible)
    try registry.saveConnection(connection, apiKey: "sk-test-1234")
    try setup.chooseCloud(connectionID: connection.id, model: "cloud-test")
    XCTAssertTrue(setup.leavesThisMac)
    XCTAssertNotNil(setup.cloudConsentAt)
  }

  private func card(_ id: Int64, _ title: String, _ start: String, _ end: String) -> TimelineCard {
    TimelineCard(
      recordId: id, batchId: 1, startTimestamp: start, endTimestamp: end, category: "Work", subcategory: "", title: title,
      summary: "", detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
      appSites: AppSites(primary: "Xcode", secondary: nil))
  }

  private var cards: [TimelineCard] {
    [
      card(1, "BEFORE-MARKER early mail", "6:00 AM", "6:30 AM"),
      card(2, "INSIDE-MARKER drafting the report", "9:00 AM", "9:30 AM"),
      card(3, "AFTER-MARKER evening video", "12:00 PM", "12:30 PM"),
    ]
  }

  /// A labeller whose model client is the REAL client on the recorder's session.
  private func labeller() -> FlowCardLabeller {
    let clock = self.clock
    let cards = self.cards
    return FlowCardLabeller(
      store: store, setup: setup, client: TBDFlowModelClient(session: FlowEgressRecorder.session()),
      cardsForDay: { _ in cards }, now: { clock.now }, calendar: Self.utc)
  }

  func testCloudWithConsentButTheObserverSwitchOffSendsNothing() async throws {
    XCTAssertFalse(setup.watching)
    let stored = await labeller().run()
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(FlowEgressRecorder.requests.count, 0, "zero requests reached the connection")
    XCTAssertTrue(store.cardLabels.isEmpty)
  }

  func testNegativeControlTheSameSetupWithTheSwitchOnReachesTheRecorder() async throws {
    setup.watching = true
    let stored = await labeller().run()
    XCTAssertEqual(stored, 1)
    let requests = FlowEgressRecorder.requests
    XCTAssertEqual(requests.count, 1, "the recorder works: the call was seen")
    XCTAssertEqual(requests.first?.url.host, "llm.example.test")
    XCTAssertTrue(requests.first?.url.path.hasSuffix("/chat/completions") == true)
  }

  func testNoRequestBodyHoldsACardOutsideThePlanButTheInPlanCardAndTheTasksAreSent() async throws {
    setup.watching = true
    _ = await labeller().run()
    let requests = FlowEgressRecorder.requests
    XCTAssertFalse(requests.isEmpty, "the control sees the call")
    for request in requests {
      XCTAssertFalse(request.body.contains("BEFORE-MARKER"), "a card before the plan is never sent")
      XCTAssertFalse(request.body.contains("AFTER-MARKER"), "a card after the plan is never sent")
    }
    XCTAssertTrue(requests.contains { $0.body.contains("INSIDE-MARKER") }, "the card inside the plan is sent")
    XCTAssertTrue(requests.contains { $0.body.contains("PLANTITLE-MARKER") }, "task titles go too, as the consent sentence says")
    XCTAssertEqual(Set(store.cardLabels.keys), ["2"], "no label for a card outside the plan")
  }

  func testTurningTheSwitchOffAgainStopsTheNextRun() async throws {
    setup.watching = true
    let first = labeller()
    _ = await first.run()
    let seen = FlowEgressRecorder.requests.count
    XCTAssertGreaterThan(seen, 0)
    setup.watching = false
    store = makeStore()  // a fresh list file in the same folder: labels start empty
    let second = labeller()
    let stored = await second.run()
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(FlowEgressRecorder.requests.count, seen, "no new request after the switch went off")
  }

  func testTheConsentSentenceSaysTheTitlesGoThereToo() {
    XCTAssertEqual(
      TBDFlowObserverSetup.consentSentence(provider: "Anthropic"),
      "Every 15 seconds a screenshot goes to Anthropic. The titles of your timeline cards and tasks also go there, to sort your day. Use this only if you accept that.")
  }
}
