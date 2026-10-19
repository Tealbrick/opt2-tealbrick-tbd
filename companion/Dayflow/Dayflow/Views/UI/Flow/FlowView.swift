//
//  FlowView.swift
//  TBD
//
//  The Flow page: today's plan on this Mac, the observer and the nudge preview. Layout follows the approved mockup
//  (coordination/leads/tbd/flow-mockups-20261019, "today-local"). Slice F2 shows the local list only; the plan-vs-actual
//  strip is F5 and the Task Board source is F4.
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
  @State private var tab: FlowTab
  private let showsTasklistImport: Bool

  init(planner: FlowPlanner = .shared, tab: FlowTab = .today, showsTasklistImport: Bool = TBDTasklistImport.isAvailable) {
    self.planner = planner
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
          observerPlaceholder
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
        TBDTag(mirror.observer.status, status: .idle)
      }
    }
  }

  // MARK: Observer (slice F3 replaces this)

  private var observerPlaceholder: some View {
    VStack(alignment: .leading, spacing: TBDKit.s2) {
      Text("The observer comes in the next step").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      Text("It will check on this Mac if you work on your plan, and nudge you when you drift. Until then you can try the nudges in Nudge preview.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(TBDKit.s4)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}
