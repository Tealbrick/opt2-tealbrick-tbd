//
//  FlowView.swift
//  TBD
//
//  The Flow page: today's plan on this Mac, the observer and the nudge preview. Layout follows the approved mockup
//  (coordination/leads/tbd/flow-mockups-20261019, "today-local"). The Observer tab is `FlowObserverView` (slice F3); the
//  plan-vs-actual strip is F5 and the Task Board source is F4.
//

import SwiftUI
import TBDDesign
import TBDModels

enum FlowTab: String, CaseIterable {
  case today, observer, nudge

  var title: String {
    switch self {
    case .today: return "Today"
    case .observer: return "Observer"
    case .nudge: return "Nudge preview"
    }
  }
}

struct FlowView: View {
  @ObservedObject var planner: FlowPlanner
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @ObservedObject private var observer: FlowDistractionAgent
  @StateObject private var observerModel: FlowObserverModel
  @State private var tab: FlowTab
  private let showsTasklistImport: Bool

  init(
    planner: FlowPlanner = .shared, tab: FlowTab = .today, showsTasklistImport: Bool = TBDTasklistImport.isAvailable,
    observer: FlowDistractionAgent = .shared, observerModel: FlowObserverModel? = nil
  ) {
    self.planner = planner
    self.observer = observer
    _observerModel = StateObject(wrappedValue: observerModel ?? FlowObserverModel())
    _tab = State(initialValue: tab)
    self.showsTasklistImport = showsTasklistImport
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: TBDKit.s5) {
        header
        TBDSegmented(selection: $tab, options: FlowTab.allCases.map { ($0, $0.title) })
        switch tab {
        case .today:
          FlowTodayView(planner: planner, showsTasklistImport: showsTasklistImport)
        case .observer:
          FlowObserverView(observer: observer, model: observerModel)
        case .nudge:
          FlowDemoView()
        }
      }
      .padding(TBDKit.s8)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  // MARK: Header

  private var headerLabel: String {
    switch tab {
    case .today: return "Companion · Today's plan · " + Self.dayLabel(planner.clock)
    case .observer: return "Companion · Observer"
    case .nudge: return "Companion · Nudge preview"
    }
  }

  /// "Monday 19 October".
  static func dayLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = .current
    f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    return f.string(from: date)
  }

  private var observerTagStatus: TBDStatus {
    if observer.status.hasPrefix("Last check") { return .live }
    return observer.lastError != nil ? .needsYou : .idle
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: TBDKit.s4) {
      VStack(alignment: .leading, spacing: TBDKit.s1) {
        Text("Flow").font(TBDTokens.Typography.display).tracking(TBDTokens.Typography.displayTracking)
          .foregroundStyle(TBDColor.ink)
        Text(headerLabel).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      Spacer(minLength: 0)
      HStack(spacing: TBDKit.s2) {
        TBDTag("Only on this Mac", status: .idle)
        TBDTag(observer.status, status: observerTagStatus)
      }
    }
  }
}
