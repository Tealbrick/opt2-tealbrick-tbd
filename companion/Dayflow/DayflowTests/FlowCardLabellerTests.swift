import XCTest
import TBDModels

@testable import TBD

/// The model matcher for timeline cards: one call per finished, unlabelled card; labels stored `by: .model`; a person's
/// label stays on top; the card id is the record id.
@MainActor
final class FlowCardLabellerTests: FlowObserverTestCase {
  private let day = "2026-10-05"
  private var store: TBDFlowStore!
  private var cards: [TimelineCard] = []
  private var requestedDays: [String] = []
  private var labeller: FlowCardLabeller!
  private var reportTask: TBDFlowTask!
  private var mailTask: TBDFlowTask!

  override func setUp() async throws {
    try await super.setUp()
    clock.set("2026-10-05T12:00:00Z")
    store = makeStore()
    reportTask = try store.addTask(title: "Write report", day: day, startAt: at("08:00:00Z"), endAt: at("11:00:00Z"))
    mailTask = try store.addTask(title: "Answer email", day: day, startAt: at("08:00:00Z"), endAt: at("11:30:00Z"))
    labeller = makeLabeller()
  }

  private func makeLabeller() -> FlowCardLabeller {
    let clock = self.clock
    return FlowCardLabeller(
      store: store, setup: setup, client: model,
      cardsForDay: { [unowned self] day in
        MainActor.assumeIsolated { self.requestedDays.append(day); return self.cards }
      },
      now: { clock.now }, calendar: Self.utc)
  }

  private func card(_ id: Int64?, _ title: String, _ start: String, _ end: String, summary: String = "", category: String = "Work")
    -> TimelineCard
  {
    TimelineCard(
      recordId: id, batchId: 1, startTimestamp: start, endTimestamp: end, category: category, subcategory: "", title: title,
      summary: summary, detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
      appSites: AppSites(primary: "Xcode", secondary: nil))
  }

  func testWritesModelLabelsKeyedByRecordId() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    XCTAssertFalse(setup.watching, "the labeller does not need the screen switch")
    cards = [
      card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM", summary: "Wrote the intro."),
      card(102, "Scrolling a video feed", "8:40 AM", "9:00 AM"),
      card(103, "Lunch away from the desk", "9:00 AM", "9:30 AM"),
    ]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    model.queue(#"{"label":"off_plan","task":null}"#)
    model.queue(#"{"label":"break","task":null}"#)
    let stored = await labeller.run()
    XCTAssertEqual(stored, 3)
    let labels = store.cardLabels
    XCTAssertEqual(Set(labels.keys), ["101", "102", "103"], "the record id, not the random TimelineCard.id")
    XCTAssertEqual(labels["101"]?.label, .onPlan)
    XCTAssertEqual(labels["101"]?.taskID, reportTask.id)
    XCTAssertEqual(labels["101"]?.by, .model)
    XCTAssertEqual(labels["102"]?.label, .offPlan)
    XCTAssertNil(labels["102"]?.taskID)
    XCTAssertEqual(labels["103"]?.label, .rest)
    XCTAssertEqual(requestedDays, [day])
    XCTAssertEqual(labeller.lastRunSummary, "Labelled 3 cards.")
  }

  func testThePromptHasTheTaskListAndTheCardAndNoImage() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM", summary: "Wrote the intro.")]
    await labeller.run()
    let call = try XCTUnwrap(model.calls.first)
    XCTAssertNil(call.imageJPEG)
    XCTAssertTrue(call.userText.contains("[g1] Write report"))
    XCTAssertTrue(call.userText.contains("[g2] Answer email"))
    XCTAssertTrue(call.userText.contains("Title: Drafting the quarterly report"))
    XCTAssertTrue(call.userText.contains("Summary: Wrote the intro."))
    XCTAssertTrue(call.userText.contains("Apps: Xcode"))
    XCTAssertEqual(call.config.baseURL.absoluteString, "http://localhost:11434/v1")
  }

  func testAPersonLabelIsNeverOverwrittenAndNeverAsked() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    try store.setCardLabel(cardID: "101", label: .offPlan, by: .person)
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    let stored = await labeller.run()
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(model.calls.count, 0, "a labelled card costs no call")
    XCTAssertEqual(store.cardLabels["101"]?.by, .person)
    XCTAssertEqual(store.cardLabels["101"]?.label, .offPlan)
  }

  func testAPersonLabelThatAppearsDuringTheCallStaysOnTop() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    let store = self.store!
    let racing = RacingModel { try? store.setCardLabel(cardID: "101", label: .rest, by: .person) }
    let racer = FlowCardLabeller(
      store: store, setup: setup, client: racing, cardsForDay: { [cards] _ in cards }, now: { [clock] in clock.now }, calendar: Self.utc)
    let stored = await racer.run()
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(store.cardLabels["101"]?.by, .person)
    XCTAssertEqual(store.cardLabels["101"]?.label, .rest)
  }

  func testAModelLabelReplacesARuleLabelButNotTheOtherWayAround() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    try store.setCardLabel(cardID: "101", label: .offPlan, by: .rule)
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    ran = await labeller.run()
    XCTAssertEqual(ran, 1)
    XCTAssertEqual(store.cardLabels["101"]?.by, .model)
    // A model label is not asked again.
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 1)
  }

  func testAtMostTwentyCallsPerRun() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    // Spread over two hours so every time is valid.
    cards = (0..<25).map { i in
      card(Int64(200 + i), "Card \(i)", "\(8 + (i * 4) / 60):\(String(format: "%02d", (i * 4) % 60)) AM", "\(8 + (i * 4 + 3) / 60):\(String(format: "%02d", (i * 4 + 3) % 60)) AM")
    }
    for _ in 0..<25 { model.queue(#"{"label":"off_plan","task":null}"#) }
    let stored = await labeller.run()
    XCTAssertEqual(stored, 20)
    XCTAssertEqual(model.calls.count, 20)
    // The next run takes the rest.
    ran = await labeller.run()
    XCTAssertEqual(ran, 5)
    XCTAssertEqual(model.calls.count, 25)
  }

  func testUnfinishedAndRecordlessCardsAreSkipped() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    clock.set("2026-10-05T08:30:30Z")
    cards = [
      card(101, "Still running", "8:00 AM", "8:30 AM"),  // ended 30 s ago
      card(102, "Settled", "7:50 AM", "8:20 AM"),
      card(nil, "No record id", "7:00 AM", "7:30 AM"),
    ]
    model.queue(#"{"label":"off_plan","task":null}"#)
    ran = await labeller.run()
    XCTAssertEqual(ran, 1)
    XCTAssertEqual(Set(store.cardLabels.keys), ["102"])
  }

  func testUnusableRepliesLeaveTheCardToTheRules() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = [card(101, "A", "8:00 AM", "8:20 AM"), card(102, "B", "8:20 AM", "8:40 AM"), card(103, "C", "8:40 AM", "9:00 AM")]
    model.queue("no idea")
    model.queue(#"{"label":"on_plan","task":"g9"}"#)  // not on the list
    model.queue(#"{"label":"on_plan","task":null}"#)
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertTrue(store.cardLabels.isEmpty)
  }

  func testThreeFailuresInARowEndTheRun() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = (0..<6).map { i in card(Int64(300 + i), "Card \(i)", "8:\(String(format: "%02d", i * 5)) AM", "8:\(String(format: "%02d", i * 5 + 4)) AM") }
    model.fallback = .failure(TBDFlowModelError.unreachable(isLocal: true))
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 3)
  }

  func testNoRouteOrNoConsentMeansNoCall() async throws {
    var ran = 0
    cards = [card(101, "A", "8:00 AM", "8:20 AM")]
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(labeller.lastRunSummary, "Set up a model for the Flow observer in Flow › Observer.")
    // Cloud without the person's choice.
    let connection = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
    try registry.saveConnection(connection, apiKey: "sk-test-1234")
    try registry.assign(TBDModelRoute(connectionID: connection.id, model: "claude-test"), to: "flow")
    setup.mode = .cloud
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 0)
    // With the choice but with the observer switch off: still no call (card and task titles would leave this Mac).
    try setup.chooseCloud(connectionID: connection.id, model: "claude-test")
    XCTAssertFalse(setup.watching)
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 0)
    XCTAssertEqual(labeller.lastRunSummary, "The cloud model gets nothing while \"Watch my screen for focus\" is off.")
    // With the choice and the switch on it runs.
    setup.watching = true
    model.queue(#"{"label":"off_plan","task":null}"#)
    ran = await labeller.run()
    XCTAssertEqual(ran, 1)
    XCTAssertEqual(model.calls.first?.config.baseURL.host, "api.anthropic.com")
    // The switch goes off again: the next run asks nothing.
    setup.watching = false
    cards = [card(102, "Another card", "8:45 AM", "9:00 AM")]
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 1)
  }

  func testALocalRouteStillRunsWithTheSwitchOff() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    XCTAssertFalse(setup.watching)
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    let stored = await labeller.run()
    XCTAssertEqual(stored, 1, "a local route does not need the screen switch")
  }

  func testACardOutsideThePlanIsNeverSentAndNeverLabelled() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    // The plan runs 8:00 to 11:30. One card is before it, one after it, one inside.
    clock.set("2026-10-05T14:00:00Z")
    cards = [
      card(101, "BEFORE-MARKER early mail", "6:00 AM", "6:30 AM"),
      card(102, "INSIDE-MARKER drafting the report", "9:00 AM", "9:30 AM"),
      card(103, "AFTER-MARKER evening video", "12:00 PM", "12:30 PM"),
    ]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    let stored = await labeller.run()
    XCTAssertEqual(stored, 1)
    XCTAssertEqual(model.calls.count, 1, "one call: only the card inside the plan")
    let text = try XCTUnwrap(model.calls.first).userText
    XCTAssertTrue(text.contains("INSIDE-MARKER"))
    XCTAssertFalse(text.contains("BEFORE-MARKER"))
    XCTAssertFalse(text.contains("AFTER-MARKER"))
    XCTAssertEqual(Set(store.cardLabels.keys), ["102"], "no label for a card outside the plan")
  }

  func testALabelKeepsItsCardWhenCompanionRebuildsItWithANewId() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = [card(101, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    model.queue(#"{"label":"on_plan","task":"g1"}"#)
    _ = await labeller.run()
    XCTAssertEqual(store.cardLabels["101"]?.start, at("08:00:00Z"), "the label stores its card's span")
    XCTAssertEqual(store.cardLabels["101"]?.end, at("08:40:00Z"))
    // Companion rebuilt the card: new record id, same time.
    cards = [card(555, "Drafting the quarterly report", "8:00 AM", "8:40 AM")]
    let again = await labeller.run()
    XCTAssertEqual(again, 0, "no second call: the label moved to the new card")
    XCTAssertEqual(model.calls.count, 1)
    XCTAssertNil(store.cardLabels["101"])
    XCTAssertEqual(store.cardLabels["555"]?.label, .onPlan)
  }

  func testNoPlanMeansNoCall() async throws {
    var ran = 0
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    try store.deleteTask(id: reportTask.id)
    try store.deleteTask(id: mailTask.id)
    cards = [card(101, "A", "8:00 AM", "8:20 AM")]
    ran = await labeller.run()
    XCTAssertEqual(ran, 0)
    XCTAssertEqual(model.calls.count, 0)
  }

  func testRunNowDoesNotOverlapItself() async throws {
    try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
    cards = [card(101, "A", "8:00 AM", "8:20 AM")]
    let first = labeller.runNow()
    XCTAssertNotNil(first)
    XCTAssertNil(labeller.runNow(), "one run at a time")
    await first?.value
    XCTAssertNotNil(labeller.runNow())
  }

  func testCardTimesAndEvidence() throws {
    let evidence = try XCTUnwrap(FlowCardLabeller.evidence(for: card(7, "T", "11:30 PM", "12:15 AM", summary: "S"), calendar: Self.utc))
    XCTAssertEqual(evidence.id, "7")
    XCTAssertEqual(evidence.start, at("23:30:00Z"))
    XCTAssertEqual(evidence.end, TBDFlowISO.date("2026-10-06T00:15:00Z"))
    XCTAssertEqual(evidence.apps, ["Xcode"])
    // After midnight but before 4 AM still belongs to the Companion day.
    XCTAssertEqual(FlowCardLabeller.clock("2:00 AM", day: day, calendar: Self.utc), TBDFlowISO.date("2026-10-06T02:00:00Z"))
    XCTAssertEqual(FlowCardLabeller.companionDay(TBDFlowISO.date("2026-10-06T02:00:00Z")!, calendar: Self.utc), day)
    XCTAssertEqual(FlowCardLabeller.companionDay(TBDFlowISO.date("2026-10-06T04:00:00Z")!, calendar: Self.utc), "2026-10-06")
    XCTAssertNil(FlowCardLabeller.evidence(for: card(nil, "T", "8:00 AM", "9:00 AM"), calendar: Self.utc))
    XCTAssertNil(FlowCardLabeller.evidence(for: card(8, "T", "soon", "later"), calendar: Self.utc))
  }

  func testParse() {
    let plan = [reportTask!, mailTask!]
    XCTAssertEqual(FlowCardLabeller.parse(#"{"label":"on_plan","task":"g2"}"#, plan: plan)?.taskID, mailTask.id)
    XCTAssertEqual(FlowCardLabeller.parse("```json\n{\"label\":\"Off_Plan\",\"task\":null}\n```", plan: plan)?.label, .offPlan)
    XCTAssertEqual(FlowCardLabeller.parse(#"{"label":"break"}"#, plan: plan)?.label, .rest)
    XCTAssertNil(FlowCardLabeller.parse(#"{"label":"on_plan","task":"g0"}"#, plan: plan))
    XCTAssertNil(FlowCardLabeller.parse(#"{"label":"maybe"}"#, plan: plan))
  }
}

/// A model that runs a side effect during the call (a person labels the card while the model thinks).
private final class RacingModel: TBDFlowModelCompleting, @unchecked Sendable {
  private let during: @Sendable () -> Void
  init(during: @escaping @Sendable () -> Void) { self.during = during }
  func complete(system: String, userText: String, imageJPEG: Data?, config: TBDModelConfig, timeout: TimeInterval) async throws -> String {
    during()
    return #"{"label":"on_plan","task":"g1"}"#
  }
}
