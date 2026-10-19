//
//  FlowCardLabeller.swift
//  TBD
//
//  The model matcher for Companion's timeline cards (DESIGN-FLOW 2.4, second in the order person > model > rule). Every
//  five minutes, and when the Flow page opens, it takes today's finished cards that have no person or model label and asks
//  the observer's model one short question per card: on plan (which task), off plan, or break. The answer is stored with
//  `by: .model`; the store keeps a person's correction on top. Cards without a model label still get the rule label at
//  read time (`TBDFlowMatcher`).
//
//  It reads card text only (titles, summaries, apps, times) and the titles of today's tasks. A local route runs as
//  before and does not need the "watch my screen" switch. A cloud route runs ONLY while the switch is on AND the person
//  chose the cloud model (`TBDFlowObserverSetup.resolve()` checks the choice, `leavesThisMac` marks the route): with the
//  switch off, nothing leaves this Mac. A card outside the plan is never sent and never gets a label.
//

import Foundation
import TBDModels

@MainActor
final class FlowCardLabeller: ObservableObject {
  static let shared = FlowCardLabeller()

  /// At most this many model calls in one run.
  static let maxCallsPerRun = 20
  /// A run stops early after this many failed calls in a row (the endpoint is down).
  static let maxFailuresInARow = 3
  /// A card is labelled once it has ended this long ago (Companion may still extend the newest card).
  static let settleSeconds: TimeInterval = 60
  /// A card the model could not label is tried at most this often.
  static let maxAttemptsPerCard = 3
  static let interval: TimeInterval = 5 * 60
  static let timeout: TimeInterval = 60

  /// The last run, for the debug text: "Labelled 3 cards."
  @Published private(set) var lastRunSummary: String?

  private let store: TBDFlowStore
  private let setup: TBDFlowObserverSetup
  private let client: TBDFlowModelCompleting
  private let cardsForDay: (String) -> [TimelineCard]
  private let now: () -> Date
  private let calendar: Calendar
  private var timer: Timer?
  private var running = false
  private var attempts: [String: Int] = [:]

  init(
    store: TBDFlowStore? = nil, setup: TBDFlowObserverSetup = TBDFlowObserverSetup(),
    client: TBDFlowModelCompleting = TBDFlowModelClient(),
    cardsForDay: @escaping (String) -> [TimelineCard] = { StorageManager.shared.fetchTimelineCards(forDay: $0) },
    now: @escaping () -> Date = { Date() }, calendar: Calendar = .current
  ) {
    self.store = store ?? FlowPlanner.shared.store
    self.setup = setup
    self.client = client
    self.cardsForDay = cardsForDay
    self.now = now
    self.calendar = calendar
  }

  // MARK: - Schedule

  /// Starts the five-minute timer (the AppDelegate calls it; never in the XCTest host).
  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.runNow() }
    }
    runNow()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  /// A run in the background (the Flow page calls it when it opens). Returns the task for tests.
  @discardableResult
  func runNow() -> Task<Void, Never>? {
    guard !running else { return nil }
    running = true
    let task = Task<Void, Never> { [weak self] in
      await self?.run()
      self?.running = false
    }
    return task
  }

  // MARK: - One run

  /// Labels up to `maxCallsPerRun` cards. Returns how many labels were stored.
  @discardableResult
  func run() async -> Int {
    let route: TBDFlowObserverRoute
    do { route = try setup.resolve() } catch {
      lastRunSummary = error.localizedDescription
      return 0
    }
    // Cloud: the switch must be on as well. Card and task titles go to the provider, so no switch, no call.
    if setup.leavesThisMac, !setup.watching {
      lastRunSummary = "The cloud model gets nothing while \"Watch my screen for focus\" is off."
      return 0
    }
    let current = now()
    let day = Self.companionDay(current, calendar: calendar)
    let tasks = store.state.tasks.filter { $0.day == day && $0.status != .cancelled }
    let plan = tasks.filter { !TBDFlowSession.isBreak($0) }
    guard !plan.isEmpty else {
      lastRunSummary = "No plan for today."
      return 0
    }
    let cards = cardsForDay(day).compactMap { Self.evidence(for: $0, calendar: calendar) }
    // A card Companion rebuilt keeps its label before anything is asked again.
    _ = try? store.reattachCardLabels(to: cards)
    let labels = store.cardLabels
    let pending = cards.filter { card in
      card.end.addingTimeInterval(Self.settleSeconds) <= current
        && (labels[card.id].map { $0.by == .rule } ?? true)
        && attempts[card.id, default: 0] < Self.maxAttemptsPerCard
        // Outside the plan (before the first task or after the last): not sent, no label.
        && TBDFlowMatcher.propose(card: card, tasks: tasks) != nil
    }
    var stored = 0
    var calls = 0
    var failures = 0
    for card in pending {
      guard calls < Self.maxCallsPerRun, failures < Self.maxFailuresInARow else { break }
      calls += 1
      attempts[card.id, default: 0] += 1
      do {
        let reply = try await client.complete(
          system: Self.system, userText: Self.prompt(card: card, plan: plan), imageJPEG: nil, config: route.config,
          timeout: Self.timeout)
        failures = 0
        guard let answer = Self.parse(reply, plan: plan) else { continue }
        // The store keeps a person's label on top (it returns false then).
        if (try? store.setCardLabel(
          cardID: card.id, label: answer.label, taskID: answer.taskID, by: .model, at: now(), cardStart: card.start,
          cardEnd: card.end)) == true
        {
          stored += 1
        }
      } catch {
        failures += 1
      }
    }
    lastRunSummary = stored == 1 ? "Labelled 1 card." : "Labelled \(stored) cards."
    return stored
  }

  // MARK: - Cards

  /// The Companion day (a day runs from 4 AM to 4 AM) that `date` falls in, as `yyyy-MM-dd`. Companion's own rule
  /// (`Date.getDayInfoFor4AMBoundary`), so Flow and the timeline pick the same cards.
  static func companionDay(_ date: Date, calendar: Calendar) -> String {
    date.getDayInfoFor4AMBoundary(calendar: calendar).dayString
  }

  /// A card as the matcher reads it. The stable id is the database record id (`TimelineCard.id` is a random UUID per
  /// fetch). nil for a card without a record id or with times that cannot be read.
  static func evidence(for card: TimelineCard, calendar: Calendar) -> TBDFlowCardEvidence? {
    guard let recordId = card.recordId,
      let start = clock(card.startTimestamp, day: card.day, calendar: calendar),
      var end = clock(card.endTimestamp, day: card.day, calendar: calendar)
    else { return nil }
    if end < start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
    let apps = [card.appSites?.primary, card.appSites?.secondary].compactMap { $0 }.filter { !$0.isEmpty }
    return TBDFlowCardEvidence(
      id: String(recordId), start: start, end: end, title: card.title, summary: card.summary, apps: apps,
      category: card.category)
  }

  /// "10:42 AM" on the Companion day `day`; times before 4 AM belong to the next calendar day.
  static func clock(_ text: String, day: String, calendar: Calendar) -> Date? {
    guard let minutes = parseTimeHMMA(timeString: text), let parts = TBDFlowDay.components(day) else { return nil }
    var components = DateComponents()
    components.year = parts.year
    components.month = parts.month
    components.day = parts.day
    guard let midnight = calendar.date(from: components) else { return nil }
    let base = minutes < 4 * 60 ? calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight : midnight
    return calendar.date(byAdding: .minute, value: minutes, to: base)
  }

  // MARK: - Prompt and answer

  static let system = """
    You label one entry of a person's activity timeline against their plan for today. \
    You get the open task list with short ids in brackets, then one timeline entry. \
    Decide: "on_plan" when the entry is work on one of the tasks (give its id), "off_plan" when it is something else, \
    "break" when the person was resting or away. When unsure between on_plan and off_plan, choose off_plan. \
    Reply with exactly one JSON object and nothing else: {"label": "on_plan" | "off_plan" | "break", "task": "g2" | null}
    """

  static func prompt(card: TBDFlowCardEvidence, plan: [TBDFlowTask]) -> String {
    let list = plan.enumerated().map { index, task in
      "[g\(index + 1)] \(task.title)" + (task.status == .done ? " (done)" : "")
    }.joined(separator: "\n")
    var lines = ["Tasks for today:", list, "", "Timeline entry:", "Title: \(card.title)"]
    if !card.summary.isEmpty { lines.append("Summary: \(card.summary)") }
    if !card.apps.isEmpty { lines.append("Apps: " + card.apps.joined(separator: ", ")) }
    lines.append("Time: \(FlowSessionTimeline.clock(card.start))–\(FlowSessionTimeline.clock(card.end))")
    lines.append("Reply with the JSON object only.")
    return lines.joined(separator: "\n")
  }

  private struct Answer: Decodable {
    let label: String?
    let task: String?
  }

  /// The label from a reply; nil when the reply is not usable (the card stays with the rules).
  static func parse(_ reply: String, plan: [TBDFlowTask]) -> (label: TBDFlowLabel, taskID: String?)? {
    guard let object = FlowDistractionAgent.jsonObjects(in: reply).first,
      let answer = try? JSONDecoder().decode(Answer.self, from: Data(object.utf8))
    else { return nil }
    switch answer.label?.lowercased() {
    case "on_plan":
      guard let short = answer.task else { return nil }
      let digits = short.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "g[] "))
      guard let index = Int(digits), index >= 1, index <= plan.count else { return nil }
      return (.onPlan, plan[index - 1].id)
    case "off_plan": return (.offPlan, nil)
    case "break": return (.rest, nil)
    default: return nil
    }
  }
}
