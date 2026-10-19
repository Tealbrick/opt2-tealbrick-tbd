import XCTest
import TBDModels

@testable import TBD

/// F5: plan vs actual from Companion's timeline: labels, minutes, totals, the strip, the off-plan cards, the "This was…"
/// menu and the person's correction.
@MainActor
final class FlowDayModelTests: FlowTestCase {
  private let day = "2026-10-05"

  override func setUp() async throws {
    try await super.setUp()
    clock.set("2026-10-05T12:00:00Z")
  }

  private func card(
    _ id: Int64, _ start: String, _ end: String, _ title: String, category: String = "Work", apps: String? = nil
  ) -> TimelineCard {
    TimelineCard(
      recordId: id, batchId: 1, startTimestamp: start, endTimestamp: end, category: category, subcategory: "", title: title,
      summary: "", detailedSummary: "", day: day, distractions: nil, videoSummaryURL: nil, otherVideoSummaryURLs: nil,
      appSites: apps.map { AppSites(primary: $0, secondary: nil) })
  }

  /// Two tasks (08:00-10:00 report, 11:00-11:30 review) and the cards described in each test.
  private struct Day {
    let planner: FlowPlanner
    let store: TBDFlowStore
    let model: FlowDayModel
    let report: TBDFlowTask
    let review: TBDFlowTask
  }

  private func makeDay(cards: [TimelineCard], tasks: Bool = true) throws -> Day {
    let store = makeStore()
    let report = try store.addTask(title: "Write quarterly report", day: day, startAt: at("08:00:00Z"), endAt: at("10:00:00Z"))
    let review = try store.addTask(title: "Weekly review", day: day, startAt: at("11:00:00Z"), endAt: at("11:30:00Z"))
    if !tasks {
      try store.deleteTask(id: report.id)
      try store.deleteTask(id: review.id)
    }
    let planner = makePlanner(store: store, cards: cards)
    planner.load()
    let model = FlowDayModel(planner: planner, modelSource: { "by TBD (model on this Mac)" })
    return Day(planner: planner, store: store, model: model, report: report, review: review)
  }

  /// The cards every test shares. Ids: 1 report (rule: on plan), 2 news (rule: off plan), 3 coffee (idle: break), 4 inbox
  /// (off plan), 5 video (off plan), 6 chat (off plan), 7 early mail (before the plan: outside), 8 later chat (after the
  /// plan: outside), 9 not finished yet (12:30 is after the clock).
  private var cards: [TimelineCard] {
    [
      card(1, "8:00 AM", "8:45 AM", "Quarterly report draft", apps: "Pages"),
      card(2, "8:45 AM", "9:15 AM", "News and social", apps: "Safari"),
      card(3, "9:15 AM", "9:30 AM", "Coffee", category: "Idle"),
      card(4, "10:00 AM", "10:45 AM", "Inbox", apps: "Mail"),
      card(5, "10:45 AM", "11:00 AM", "Short videos"),
      card(6, "11:00 AM", "11:10 AM", "Chat"),
      card(7, "7:00 AM", "7:30 AM", "Early mail"),
      card(8, "11:30 AM", "12:00 PM", "Later chat"),
      card(9, "11:50 AM", "12:30 PM", "Still running"),
    ]
  }

  private func dayCard(_ model: FlowDayModel, _ id: String) throws -> FlowDayCard {
    try XCTUnwrap(model.snapshot.cards.first { $0.id == id }, "card \(id)")
  }

  // MARK: Labels and precedence

  func testRuleLabelsWhenNothingIsStored() throws {
    let d = try makeDay(cards: cards)
    XCTAssertEqual(try dayCard(d.model, "1").label?.label, .onPlan)
    XCTAssertEqual(try dayCard(d.model, "1").taskTitle, "Write quarterly report")
    XCTAssertEqual(try dayCard(d.model, "2").label?.label, .offPlan)
    XCTAssertEqual(try dayCard(d.model, "3").label?.label, .rest)
    XCTAssertEqual(try dayCard(d.model, "1").label?.by, .rule)
  }

  func testPersonBeatsModelBeatsRule() throws {
    let d = try makeDay(cards: cards)
    // The model says card 2 was on plan: it beats the rule (off plan).
    try d.store.setCardLabel(cardID: "2", label: .onPlan, taskID: d.report.id, by: .model)
    d.model.refresh()
    XCTAssertEqual(try dayCard(d.model, "2").label?.label, .onPlan)
    XCTAssertEqual(try dayCard(d.model, "2").label?.by, .model)
    // The person says off plan: it beats the model.
    try d.store.setCardLabel(cardID: "2", label: .offPlan, by: .person)
    d.model.refresh()
    XCTAssertEqual(try dayCard(d.model, "2").label?.label, .offPlan)
    XCTAssertEqual(try dayCard(d.model, "2").label?.by, .person)
    // A later model answer cannot overwrite the person.
    XCTAssertEqual(try d.store.setCardLabel(cardID: "2", label: .onPlan, taskID: d.report.id, by: .model), false)
    d.model.refresh()
    XCTAssertEqual(try dayCard(d.model, "2").label?.by, .person)
  }

  func testCardsOutsideThePlanHaveNoLabel() throws {
    let d = try makeDay(cards: cards)
    for id in ["7", "8"] {
      let c = try dayCard(d.model, id)
      XCTAssertNil(c.label, "card \(id)")
      XCTAssertEqual(c.kind, .outside)
      XCTAssertEqual(c.tagText, "Outside the plan")
      XCTAssertNil(d.model.provenance(c))
    }
  }

  func testUnfinishedCardsAreLeftOut() throws {
    let d = try makeDay(cards: cards)
    XCTAssertNil(d.model.snapshot.cards.first { $0.id == "9" })
    XCTAssertEqual(d.model.snapshot.cards.map(\.id), ["7", "1", "2", "3", "4", "5", "6", "8"])
  }

  // MARK: Minutes and totals

  func testOutsideThePlanIsNotCountedInTotals() throws {
    let d = try makeDay(cards: cards)
    let t = d.model.snapshot.totals
    XCTAssertEqual(t.onPlanMinutes, 45)
    XCTAssertEqual(t.offPlanMinutes, 30 + 45 + 15 + 10)
    XCTAssertEqual(t.restMinutes, 15)
    XCTAssertEqual(t.outsideMinutes, 60)
    XCTAssertEqual(d.model.totalsLine, "On plan 45 min · Off plan 1 h 40 min · Break 15 min")
  }

  func testMinutesPerTask() throws {
    let d = try makeDay(cards: cards)
    XCTAssertEqual(d.model.snapshot.minutesPerTask, [d.report.id: 45])
    // A person's correction moves minutes to another task.
    try d.store.setCardLabel(cardID: "2", label: .onPlan, taskID: d.review.id, by: .person)
    d.model.refresh()
    XCTAssertEqual(d.model.snapshot.minutesPerTask, [d.report.id: 45, d.review.id: 30])
  }

  func testPlannerMinutesMatchThePage() throws {
    let d = try makeDay(cards: cards)
    try d.store.setCardLabel(cardID: "2", label: .onPlan, taskID: d.report.id, by: .model)
    d.model.refresh()
    // F4's Task Board completion text and the page show the same minutes.
    XCTAssertEqual(d.planner.minutesOnPlan(for: d.report), Int((d.model.snapshot.minutesPerTask[d.report.id] ?? 0).rounded()))
    XCTAssertEqual(d.planner.minutesOnPlan(for: d.report), 75)
    XCTAssertEqual(d.planner.minutesOnPlan(for: d.review), 0)
  }

  func testMinutesText() {
    XCTAssertEqual(FlowDayModel.minutesText(0), "0 min")
    XCTAssertEqual(FlowDayModel.minutesText(55), "55 min")
    XCTAssertEqual(FlowDayModel.minutesText(65), "1 h 05 min")
    XCTAssertEqual(FlowDayModel.minutesText(155), "2 h 35 min")
    XCTAssertEqual(FlowDayModel.minutesText(120), "2 h")
  }

  // MARK: The strip

  func testStripOrderAndFractions() throws {
    let d = try makeDay(cards: cards)
    let s = d.model.snapshot
    XCTAssertEqual(s.planStart, at("08:00:00Z"))
    XCTAssertEqual(s.planEnd, at("11:30:00Z"))
    // Outside cards (07:00 and 11:30) are not in the strip. Neighbours of one kind are one piece (10:00-11:10 off plan).
    XCTAssertEqual(s.segments.map(\.kind), [.onPlan, .offPlan, .rest, .notTracked, .offPlan, .notTracked])
    let minutes = s.segments.map { $0.end.timeIntervalSince($0.start) / 60 }
    XCTAssertEqual(minutes, [45, 30, 15, 30, 70, 20])
    XCTAssertEqual(s.segments.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
    XCTAssertEqual(s.segments[0].fraction, 45.0 / 210.0, accuracy: 1e-9)
    // The segments touch: each starts where the one before ended.
    for (a, b) in zip(s.segments, s.segments.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    XCTAssertEqual(s.segments.first?.start, s.planStart)
    XCTAssertEqual(s.segments.last?.end, s.planEnd)
  }

  func testStripEndsWithNotTrackedYetTail() throws {
    clock.set("2026-10-05T09:00:00Z")
    let d = try makeDay(cards: [card(1, "8:00 AM", "8:45 AM", "Quarterly report draft")])
    XCTAssertEqual(d.model.snapshot.segments.map(\.kind), [.onPlan, .notTracked])
    XCTAssertEqual(d.model.snapshot.segments.last?.end, at("11:30:00Z"))
  }

  func testStripCutsACardAtThePlanEdges() throws {
    let d = try makeDay(cards: [card(1, "7:30 AM", "8:30 AM", "Quarterly report draft")])
    XCTAssertEqual(d.model.snapshot.segments.first?.kind, .onPlan)
    XCTAssertEqual(d.model.snapshot.segments.first?.start, at("08:00:00Z"))
    XCTAssertEqual(d.model.snapshot.segments.first?.end, at("08:30:00Z"))
  }

  func testNoTimesMeansNoStrip() throws {
    let store = makeStore()
    try store.addTask(title: "Think", day: day)
    let planner = makePlanner(store: store, cards: cards)
    let model = FlowDayModel(planner: planner, modelSource: { "x" })
    XCTAssertTrue(model.snapshot.hasPlan)
    XCTAssertTrue(model.snapshot.segments.isEmpty)
    XCTAssertNil(model.snapshot.planStart)
  }

  func testNoTasksMeansNoPlan() throws {
    let d = try makeDay(cards: cards, tasks: false)
    XCTAssertFalse(d.model.snapshot.hasPlan)
    XCTAssertTrue(d.model.snapshot.segments.isEmpty)
  }

  // MARK: Off plan

  func testTopOffPlanCardsByMinutes() throws {
    let d = try makeDay(cards: cards)
    // Off plan cards: inbox 45, news 30, video 15, chat 10 → the top three.
    XCTAssertEqual(d.model.snapshot.topOffPlan.map(\.id), ["4", "2", "5"])
    XCTAssertEqual(FlowDayModel.topOffPlanCount, 3)
    XCTAssertEqual(FlowOffPlanCard.detail(d.model.snapshot.topOffPlan[0]), "Mail · 45 min")
    XCTAssertEqual(FlowOffPlanCard.detail(d.model.snapshot.topOffPlan[2]), "15 min")
  }

  func testACorrectionTakesACardOutOfOffPlan() throws {
    let d = try makeDay(cards: cards)
    try d.store.setCardLabel(cardID: "4", label: .rest, by: .person)
    d.model.refresh()
    XCTAssertEqual(d.model.snapshot.topOffPlan.map(\.id), ["2", "5", "6"])
    XCTAssertEqual(d.model.snapshot.totals.offPlanMinutes, 30 + 15 + 10)
  }

  // MARK: Provenance

  func testProvenanceWords() throws {
    let d = try makeDay(cards: cards)
    try d.store.setCardLabel(cardID: "4", label: .offPlan, by: .model)
    try d.store.setCardLabel(cardID: "5", label: .rest, by: .person)
    d.model.refresh()
    XCTAssertEqual(d.model.provenance(try dayCard(d.model, "1")), "by rule (timebox and words)")
    XCTAssertEqual(d.model.provenance(try dayCard(d.model, "4")), "by TBD (model on this Mac)")
    XCTAssertEqual(d.model.provenance(try dayCard(d.model, "5")), "by you")
  }

  func testModelSourceNamesTheCloudProvider() throws {
    let suite = "Dayflow.FlowDayModelTests.\(UUID().uuidString)"
    let local = UserDefaults(suiteName: suite)!
    defer { local.removePersistentDomain(forName: suite) }
    let registry = TBDModelRegistry(defaults: local, credentials: TBDMemorySecretStore())
    let setup = TBDFlowObserverSetup(registry: registry, defaults: local)
    XCTAssertEqual(setup.mode, .textLocal)
    XCTAssertEqual(FlowDayModel.defaultModelSource(setup: setup), "by TBD (model on this Mac)")
    let connection = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
    try registry.saveConnection(connection, apiKey: "test-key-not-real")
    try setup.chooseCloud(connectionID: connection.id, model: "claude-test")
    XCTAssertEqual(setup.mode, .cloud)
    XCTAssertEqual(FlowDayModel.defaultModelSource(setup: setup), "by TBD (Anthropic)")
  }

  // MARK: The "This was…" menu

  func testMenuItemsForACard() throws {
    let d = try makeDay(cards: cards)
    let c = try dayCard(d.model, "2")
    let menu = d.model.menu(for: c)
    XCTAssertEqual(menu.heading, FlowDayModel.range(c.evidence) + " was")
    XCTAssertEqual(
      menu.choices.map(\.title),
      ["On plan: Write quarterly report", "On plan: Weekly review", "Off plan", "Break"])
    XCTAssertEqual(menu.choices.map(\.dividerAbove), [false, false, true, false])
    // Card 2 is off plan by the rule: "Off plan" is marked, nothing to clear.
    XCTAssertEqual(menu.choices.map(\.isSelected), [false, false, true, false])
    XCTAssertEqual(
      menu.choices.map(\.action), [.onPlan(taskID: d.report.id), .onPlan(taskID: d.review.id), .offPlan, .rest])
  }

  func testEachCardsMenuNamesItsOwnRange() throws {
    let d = try makeDay(cards: cards)
    let first = try dayCard(d.model, "1")
    let second = try dayCard(d.model, "2")
    XCTAssertNotEqual(d.model.menu(for: first).heading, d.model.menu(for: second).heading)
    XCTAssertTrue(d.model.menu(for: first).heading.hasSuffix(" was"))
  }

  func testMenuMarksTheOnPlanTaskAndOffersClearOnlyForAPersonLabel() throws {
    let d = try makeDay(cards: cards)
    let rule = d.model.menu(for: try dayCard(d.model, "1"))
    XCTAssertEqual(rule.choices.first { $0.isSelected }?.action, .onPlan(taskID: d.report.id))
    XCTAssertNil(rule.choices.first { $0.action == .clear })
    // A model label: still nothing to clear.
    try d.store.setCardLabel(cardID: "1", label: .onPlan, taskID: d.review.id, by: .model)
    d.model.refresh()
    XCTAssertNil(d.model.menu(for: try dayCard(d.model, "1")).choices.first { $0.action == .clear })
    // A person label: "Clear my correction" comes last, behind a divider.
    try d.store.setCardLabel(cardID: "1", label: .offPlan, by: .person)
    d.model.refresh()
    let person = d.model.menu(for: try dayCard(d.model, "1"))
    XCTAssertEqual(person.choices.last?.title, "Clear my correction")
    XCTAssertEqual(person.choices.last?.dividerAbove, true)
    XCTAssertEqual(person.choices.first { $0.isSelected }?.action, .offPlan)
  }

  func testMenuHasNoBreakTasksAsOnPlanChoices() throws {
    let store = makeStore()
    try store.addTask(title: "Write quarterly report", day: day, startAt: at("08:00:00Z"), endAt: at("10:00:00Z"))
    try store.addTask(title: TBDFlowSession.breakTitles.first!, day: day, startAt: at("10:00:00Z"), endAt: at("10:15:00Z"))
    let planner = makePlanner(store: store, cards: cards)
    let model = FlowDayModel(planner: planner, modelSource: { "x" })
    let menu = model.menu(for: try dayCard(model, "1"))
    XCTAssertEqual(menu.choices.map(\.title), ["On plan: Write quarterly report", "Off plan", "Break"])
  }

  // MARK: Corrections

  func testChoosingOffPlanWritesAPersonLabelAndQueuesTheObserverNote() throws {
    let d = try makeDay(cards: cards)
    let c = try dayCard(d.model, "1")
    let choice = try XCTUnwrap(d.model.menu(for: c).choices.first { $0.action == .offPlan })
    d.model.choose(choice, for: c)
    let stored = try XCTUnwrap(d.store.cardLabels["1"])
    XCTAssertEqual(stored.label, .offPlan)
    XCTAssertEqual(stored.by, .person)
    XCTAssertEqual(try dayCard(d.model, "1").label?.by, .person)
    XCTAssertEqual(d.model.snapshot.totals.onPlanMinutes, 0)
    XCTAssertEqual(observer.notes.map(\.text), ["The person says \(FlowDayModel.range(c.evidence)) was off plan."])
    XCTAssertEqual(observer.notes.map(\.refocused), [false])
  }

  func testChoosingATaskWritesItAndNamesTheTask() throws {
    let d = try makeDay(cards: cards)
    let c = try dayCard(d.model, "2")
    let choice = try XCTUnwrap(d.model.menu(for: c).choices.first { $0.action == .onPlan(taskID: d.review.id) })
    d.model.choose(choice, for: c)
    let stored = try XCTUnwrap(d.store.cardLabels["2"])
    XCTAssertEqual(stored.label, .onPlan)
    XCTAssertEqual(stored.taskID, d.review.id)
    XCTAssertEqual(stored.by, .person)
    XCTAssertEqual(d.model.snapshot.minutesPerTask[d.review.id], 30)
    XCTAssertEqual(observer.notes.map(\.text), ["The person says \(FlowDayModel.range(c.evidence)) was on plan: Weekly review."])
  }

  func testChoosingBreakWritesTheLabelWithoutANote() throws {
    let d = try makeDay(cards: cards)
    let c = try dayCard(d.model, "2")
    d.model.choose(try XCTUnwrap(d.model.menu(for: c).choices.first { $0.action == .rest }), for: c)
    XCTAssertEqual(d.store.cardLabels["2"]?.label, .rest)
    XCTAssertEqual(d.store.cardLabels["2"]?.by, .person)
    XCTAssertTrue(observer.notes.isEmpty)
  }

  func testClearingRemovesOnlyThePersonLabel() throws {
    let d = try makeDay(cards: cards)
    // A model label survives "clear": there is no person label to remove.
    try d.store.setCardLabel(cardID: "4", label: .offPlan, by: .model)
    d.model.refresh()
    let modelCard = try dayCard(d.model, "4")
    d.model.choose(
      FlowCardChoice(action: .clear, title: "Clear my correction", isSelected: false, dividerAbove: true), for: modelCard)
    XCTAssertEqual(d.store.cardLabels["4"]?.by, .model)
    XCTAssertEqual(try dayCard(d.model, "4").label?.by, .model)

    // A person label is removed; the card goes back to the rules (card 1: on plan by the rule).
    let c = try dayCard(d.model, "1")
    d.model.choose(try XCTUnwrap(d.model.menu(for: c).choices.first { $0.action == .offPlan }), for: c)
    XCTAssertEqual(try dayCard(d.model, "1").label?.label, .offPlan)
    let corrected = try dayCard(d.model, "1")
    d.model.choose(try XCTUnwrap(d.model.menu(for: corrected).choices.first { $0.action == .clear }), for: corrected)
    XCTAssertNil(d.store.cardLabels["1"])
    XCTAssertEqual(try dayCard(d.model, "1").label?.label, .onPlan)
    XCTAssertEqual(try dayCard(d.model, "1").label?.by, .rule)
    // Clearing sends no note; the model label of card 4 was never touched.
    XCTAssertEqual(observer.notes.count, 1)
    XCTAssertEqual(d.store.cardLabels["4"]?.by, .model)
  }

  // MARK: Refresh

  func testTheModelFollowsTheStoreWhileTheStartIsOn() throws {
    let d = try makeDay(cards: cards)
    d.model.start()
    defer { d.model.stop() }
    XCTAssertEqual(try dayCard(d.model, "2").label?.by, .rule)
    // The labeller writes a model label; the planner notices it on its next tick and the model reads again.
    try d.store.setCardLabel(cardID: "2", label: .onPlan, taskID: d.report.id, by: .model)
    d.planner.load()
    XCTAssertEqual(try dayCard(d.model, "2").label?.by, .model)
    // A new task changes the plan.
    try d.store.addTask(title: "Inbox", day: day, startAt: at("10:00:00Z"), endAt: at("11:00:00Z"))
    d.planner.load()
    XCTAssertEqual(d.model.tasks.count, 3)
    XCTAssertEqual(try dayCard(d.model, "4").label?.label, .onPlan)
  }
}
