//
//  FlowDayModel.swift
//  TBD
//
//  Plan vs actual for today (DESIGN-FLOW 2.4, slice F5): Companion's finished timeline cards, each with the label that
//  counts (person > model > rule; nil = outside the plan), the minutes per task, the totals, the strip from the plan's
//  first start to its last end, and the top off-plan cards. No UI here: the Today and Plan vs actual tabs read
//  `snapshot`, the "This was…" menus read `menu(for:)`, and a choice goes back through `choose`.
//
//  The numbers come from `snapshot(...)`, a pure function. `FlowPlanner.minutesOnPlan` (the Task Board completion text,
//  F4) calls the same function, so the page and the text say the same minutes.
//

import Combine
import Foundation
import TBDModels

/// What the strip and the card tag call a stretch of the day.
enum FlowDayKind: Equatable {
  case onPlan, offPlan, rest
  /// A card before the first task or after the last one: not counted as off plan.
  case outside
  /// No card covers this stretch (yet).
  case notTracked
}

/// One finished Companion card with its effective label.
struct FlowDayCard: Identifiable, Equatable {
  let evidence: TBDFlowCardEvidence
  /// nil = outside the plan.
  let label: TBDFlowCardLabel?
  /// The title of the task for an on-plan label (nil when the task is gone).
  let taskTitle: String?

  var id: String { evidence.id }
  var minutes: Double { evidence.minutes }
  var kind: FlowDayKind {
    switch label?.label {
    case .onPlan?: return .onPlan
    case .offPlan?: return .offPlan
    case .rest?: return .rest
    case nil: return .outside
    }
  }
  /// "On plan: <task>", "Off plan", "Break" or "Outside the plan".
  var tagText: String {
    switch kind {
    case .onPlan: return taskTitle.map { "On plan: \($0)" } ?? "On plan"
    case .offPlan: return "Off plan"
    case .rest: return "Break"
    case .outside, .notTracked: return "Outside the plan"
    }
  }
}

/// One piece of the strip. `fraction` is its share of the plan's range (the pieces add up to 1).
struct FlowStripSegment: Equatable {
  let kind: FlowDayKind
  let start: Date
  let end: Date
  let fraction: Double
}

/// Everything the page shows, computed from the cards, the tasks and the stored labels.
struct FlowDaySnapshot: Equatable {
  /// Finished cards of the Companion day, oldest first.
  var cards: [FlowDayCard] = []
  var minutesPerTask: [String: Double] = [:]
  var totals = TBDFlowTotals()
  /// The plan's first start and last end; nil when no task has a time (no strip).
  var planStart: Date?
  var planEnd: Date?
  var segments: [FlowStripSegment] = []
  /// The (at most `FlowDayModel.topOffPlanCount`) off-plan cards with the most minutes, longest first.
  var topOffPlan: [FlowDayCard] = []
  /// Today has at least one task (not cancelled).
  var hasPlan = false
}

/// One entry of the "This was…" menu.
struct FlowCardChoice: Identifiable, Equatable {
  enum Action: Equatable {
    case onPlan(taskID: String)
    case offPlan
    case rest
    case clear
  }
  let action: Action
  let title: String
  let isSelected: Bool
  /// A divider goes above the first of each group.
  let dividerAbove: Bool
  var id: String {
    switch action {
    case .onPlan(let taskID): return "on:\(taskID)"
    case .offPlan: return "off"
    case .rest: return "rest"
    case .clear: return "clear"
    }
  }
}

/// The menu of one card: its heading names the card's time range.
struct FlowCardMenu: Equatable {
  /// "9:35 AM – 10:00 AM was".
  let heading: String
  let choices: [FlowCardChoice]
}

@MainActor
final class FlowDayModel: ObservableObject {
  /// The Off plan card shows this many cards.
  static let topOffPlanCount = 3
  /// While the page is visible the model reads the timeline again this often.
  static let refreshInterval: TimeInterval = 60

  @Published private(set) var snapshot = FlowDaySnapshot()
  /// The tasks of today in plan order (not cancelled), for the menus.
  @Published private(set) var tasks: [TBDFlowTask] = []
  /// "by TBD (model on this Mac)" or "by TBD (Anthropic)".
  @Published private(set) var modelSource: String

  private let planner: FlowPlanner
  private let sourceText: () -> String
  private var cancellables: Set<AnyCancellable> = []
  private var timer: Timer?

  init(planner: FlowPlanner = .shared, modelSource: (() -> String)? = nil) {
    self.planner = planner
    self.sourceText = modelSource ?? { Self.defaultModelSource() }
    self.modelSource = self.sourceText()
    refresh()
  }

  // MARK: - Visible

  /// The Flow page opened: read now, then every minute, and whenever the tasks or the labels change.
  func start() {
    refresh()
    if timer == nil {
      timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
    }
    guard cancellables.isEmpty else { return }
    planner.$tasks.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
    planner.$cardLabels.dropFirst().sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
  }

  /// The page closed.
  func stop() {
    timer?.invalidate()
    timer = nil
    cancellables.removeAll()
  }

  /// Reads the cards and the labels and publishes the result.
  func refresh() {
    let current = planner.currentTime
    let tasks = planner.planTasks(forDay: planner.todayKey)
    let next = Self.snapshot(
      cards: planner.timelineEvidence(), tasks: tasks, labels: planner.store.cardLabels, now: current)
    if next != snapshot { snapshot = next }
    if self.tasks != tasks { self.tasks = tasks }
    let source = sourceText()
    if source != modelSource { modelSource = source }
  }

  // MARK: - Computation

  /// The day for `cards` (all cards of the Companion day), `tasks` (today's, not cancelled) and the stored `labels`.
  /// Only finished cards (ended by `now`) count. Same numbers as `TBDFlowMatcher.minutesPerTask` / `totals`.
  static func snapshot(
    cards allCards: [TBDFlowCardEvidence], tasks: [TBDFlowTask], labels: [String: TBDFlowCardLabel], now: Date
  ) -> FlowDaySnapshot {
    var out = FlowDaySnapshot()
    out.hasPlan = !tasks.isEmpty
    let finished = allCards.filter { $0.end <= now && $0.end > $0.start }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    let titles = Dictionary(tasks.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    out.cards = finished.map { card in
      let label = TBDFlowMatcher.effectiveLabel(for: card, stored: labels, tasks: tasks, at: now)
      return FlowDayCard(evidence: card, label: label, taskTitle: label?.taskID.flatMap { titles[$0] })
    }
    out.minutesPerTask = TBDFlowMatcher.minutesPerTask(labels: labels, cards: finished, tasks: tasks)
    out.totals = TBDFlowMatcher.totals(labels: labels, cards: finished, tasks: tasks)
    out.topOffPlan = Array(
      out.cards.filter { $0.kind == .offPlan }
        .sorted { ($0.minutes, $1.evidence.start) > ($1.minutes, $0.evidence.start) }
        .prefix(topOffPlanCount))
    let starts = tasks.compactMap(\.startAt)
    let ends = tasks.compactMap { $0.endAt ?? $0.startAt }
    if let first = starts.min(), let last = ends.max(), last > first {
      out.planStart = first
      out.planEnd = last
      out.segments = segments(cards: out.cards, from: first, to: last)
    }
    return out
  }

  /// The strip: the cards cut to [start, end], in order, with a "not tracked" piece for every gap and for the tail.
  /// Cards outside the plan's range fall away; a card that overlaps the one before starts where that one ended.
  static func segments(cards: [FlowDayCard], from start: Date, to end: Date) -> [FlowStripSegment] {
    let total = end.timeIntervalSince(start)
    guard total > 0 else { return [] }
    var pieces: [(FlowDayKind, Date, Date)] = []
    var cursor = start
    for card in cards {
      let from = max(card.evidence.start, cursor)
      let to = min(card.evidence.end, end)
      guard to > from else { continue }
      if from > cursor { pieces.append((.notTracked, cursor, from)) }
      pieces.append((card.kind, from, to))
      cursor = to
    }
    if cursor < end { pieces.append((.notTracked, cursor, end)) }
    // Neighbours of the same kind are one piece (two on-plan cards in a row read as one bar).
    var merged: [(FlowDayKind, Date, Date)] = []
    for piece in pieces {
      if let last = merged.last, last.0 == piece.0, last.2 == piece.1 {
        merged[merged.count - 1].2 = piece.2
      } else {
        merged.append(piece)
      }
    }
    return merged.map { kind, from, to in
      // An outside card cannot be inside the range, but a task-less gap is drawn as untracked either way.
      FlowStripSegment(
        kind: kind == .outside ? .notTracked : kind, start: from, end: to, fraction: to.timeIntervalSince(from) / total)
    }
  }

  // MARK: - Words

  /// "45 min", "1 h 05 min", "2 h" (the mockup's form).
  static func minutesText(_ minutes: Double) -> String {
    let whole = Int(minutes.rounded())
    guard whole >= 60 else { return "\(whole) min" }
    return whole % 60 == 0 ? "\(whole / 60) h" : String(format: "%d h %02d min", whole / 60, whole % 60)
  }

  /// "On plan 2 h 35 min · Off plan 55 min · Break 15 min".
  var totalsLine: String {
    let t = snapshot.totals
    return "On plan \(Self.minutesText(t.onPlanMinutes)) · Off plan \(Self.minutesText(t.offPlanMinutes)) · Break \(Self.minutesText(t.restMinutes))"
  }

  /// "9:35 AM – 10:00 AM".
  static func range(_ card: TBDFlowCardEvidence) -> String {
    clock(card.start) + " – " + clock(card.end)
  }

  static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

  /// "Mail, Portal" (the card's apps), or "" when Companion saw none.
  static func appsText(_ card: TBDFlowCardEvidence) -> String { card.apps.joined(separator: ", ") }

  /// Who set the label, in the words of the mockup: "by you", "by TBD (model on this Mac)", "by rule (timebox and words)".
  /// nil for a card outside the plan (no label).
  func provenance(_ card: FlowDayCard) -> String? {
    switch card.label?.by {
    case .person?: return "by you"
    case .model?: return modelSource
    case .rule?: return "by rule (timebox and words)"
    case nil: return nil
    }
  }

  /// The observer's route as a source line: the cloud provider's name, or "model on this Mac".
  static func defaultModelSource(setup: TBDFlowObserverSetup = TBDFlowObserverSetup()) -> String {
    guard setup.mode == .cloud else { return "by TBD (model on this Mac)" }
    let provider = setup.currentRoute().map { TBDFlowObserverSetup.providerName($0.connection) } ?? "a cloud model"
    return "by TBD (\(provider))"
  }

  // MARK: - Correction menu

  /// The menu for one card: "On plan: <task>" for each task of today, a divider, "Off plan", "Break", and "Clear my
  /// correction" when the person set the label. The current label is marked.
  func menu(for card: FlowDayCard) -> FlowCardMenu {
    let current = card.label
    var choices: [FlowCardChoice] = []
    for task in tasks where !TBDFlowSession.isBreak(task) {
      choices.append(
        FlowCardChoice(
          action: .onPlan(taskID: task.id), title: "On plan: \(task.title)",
          isSelected: current?.label == .onPlan && current?.taskID == task.id, dividerAbove: false))
    }
    choices.append(
      FlowCardChoice(action: .offPlan, title: "Off plan", isSelected: current?.label == .offPlan, dividerAbove: !choices.isEmpty))
    choices.append(FlowCardChoice(action: .rest, title: "Break", isSelected: current?.label == .rest, dividerAbove: false))
    if current?.by == .person {
      choices.append(FlowCardChoice(action: .clear, title: "Clear my correction", isSelected: false, dividerAbove: true))
    }
    return FlowCardMenu(heading: Self.range(card.evidence) + " was", choices: choices)
  }

  /// The person picked an entry. Writes (or clears) the person's label and tells the observer.
  func choose(_ choice: FlowCardChoice, for card: FlowDayCard) {
    let range = Self.range(card.evidence)
    switch choice.action {
    case .onPlan(let taskID):
      let title = tasks.first { $0.id == taskID }?.title ?? "a task"
      planner.correctCard(card.id, label: .onPlan, taskID: taskID, note: "The person says \(range) was on plan: \(title).")
    case .offPlan:
      planner.correctCard(card.id, label: .offPlan, taskID: nil, note: "The person says \(range) was off plan.")
    case .rest:
      planner.correctCard(card.id, label: .rest, taskID: nil, note: nil)
    case .clear:
      planner.clearCardCorrection(card.id)
    }
    refresh()
  }
}
