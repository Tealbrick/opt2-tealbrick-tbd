//
//  FlowPlanVsActualView.swift
//  TBD
//
//  Plan vs actual from Companion's timeline (slice F5, mockups "today-taskboard" and "plan-vs-actual"): the day strip, the
//  "Off plan today" card, and the Plan vs actual tab with one row per finished card. Every "This was…" button is a real
//  `Menu` on its own card, so it opens at that card and its heading names that card's time range.
//

import SwiftUI
import TBDDesign
import TBDModels

// MARK: - Colours

extension FlowDayKind {
  /// The strip and the card bar.
  var fill: Color {
    switch self {
    case .onPlan: return TBDColor.teal
    case .offPlan: return TBDColor.brick
    case .rest: return TBDColor.toneStone
    case .outside, .notTracked: return TBDColor.plate
    }
  }

  var tagStatus: TBDStatus {
    switch self {
    case .onPlan: return .live
    case .offPlan: return .needsYou
    case .rest, .outside, .notTracked: return .idle
    }
  }
}

// MARK: - The "This was…" menu

/// The correction menu of one card. A system `Menu` anchored to its own button.
struct FlowCardMenuButton: View {
  @ObservedObject var model: FlowDayModel
  let card: FlowDayCard

  var body: some View {
    let menu = model.menu(for: card)
    Menu {
      // The heading is a disabled entry, so it shows in every macOS version.
      Button(menu.heading) {}.disabled(true)
      ForEach(menu.choices) { choice in
        if choice.dividerAbove { Divider() }
        Button {
          model.choose(choice, for: card)
        } label: {
          if choice.isSelected {
            Label(choice.title, systemImage: "checkmark")
          } else {
            Text(choice.title)
          }
        }
      }
    } label: {
      Text("This was…")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .buttonStyle(TBDButtonStyle(.quiet))
    .fixedSize()
    .accessibilityLabel("This was… \(FlowDayModel.range(card.evidence))")
  }
}

// MARK: - Strip card

/// "Plan vs actual · from your timeline": the day strip, the legend, the totals and the plan's start and end.
struct FlowDayStripCard: View {
  @ObservedObject var model: FlowDayModel

  var body: some View {
    let snapshot = model.snapshot
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(alignment: .firstTextBaseline, spacing: TBDKit.s4) {
        Text("Plan vs actual · from your timeline").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        Spacer(minLength: 0)
        Text(snapshot.cards.isEmpty ? "Nothing in your timeline yet" : model.totalsLine)
          .font(TBDTokens.Typography.label).foregroundStyle(TBDColor.inkSoft).multilineTextAlignment(.trailing)
      }
      if !snapshot.segments.isEmpty { strip(snapshot.segments) }
      HStack(spacing: TBDKit.s4) {
        legend(.onPlan, "On plan")
        legend(.offPlan, "Off plan")
        legend(.rest, "Break")
        legend(.notTracked, "Not tracked yet")
        Spacer(minLength: 0)
        if let start = snapshot.planStart, let end = snapshot.planEnd {
          Text(FlowDayModel.clock(start)).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          Text("–").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          Text(FlowDayModel.clock(end)).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
      }
    }
    .padding(TBDKit.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  private static let gap: CGFloat = 2

  private func strip(_ segments: [FlowStripSegment]) -> some View {
    GeometryReader { geo in
      let room = max(0, geo.size.width - Self.gap * CGFloat(segments.count - 1))
      HStack(spacing: Self.gap) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
          Rectangle().fill(segment.kind.fill).frame(width: max(2, room * CGFloat(segment.fraction)))
        }
      }
    }
    .frame(height: 18)
    .clipShape(TBDBrickShape())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Plan vs actual strip")
    .accessibilityValue(model.totalsLine)
  }

  private func legend(_ kind: FlowDayKind, _ text: String) -> some View {
    HStack(spacing: TBDKit.s1) {
      Rectangle().fill(kind.fill).frame(width: 12, height: 12)
        .overlay(Rectangle().strokeBorder(TBDColor.lineStrong, lineWidth: 1))
        .accessibilityHidden(true)
      Text(text).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft)
    }
  }
}

// MARK: - Off plan today

/// The right-column card: the off-plan total in brick ink and the top cards, each with its own "This was…" menu.
struct FlowOffPlanCard: View {
  @ObservedObject var model: FlowDayModel

  var body: some View {
    let snapshot = model.snapshot
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(alignment: .firstTextBaseline) {
        Text("Off plan today").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        Spacer(minLength: 0)
        Text(FlowDayModel.minutesText(snapshot.totals.offPlanMinutes)).font(TBDTokens.Typography.label)
          .foregroundStyle(snapshot.totals.offPlanMinutes > 0 ? TBDColor.brickInk : TBDColor.muted)
      }
      if snapshot.topOffPlan.isEmpty {
        Text("Nothing off plan so far.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      ForEach(snapshot.topOffPlan) { card in
        HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
          VStack(alignment: .leading, spacing: TBDKit.s1) {
            Text(card.evidence.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).lineLimit(2)
            Text(Self.detail(card)).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1)
          }
          Spacer(minLength: 0)
          FlowCardMenuButton(model: model, card: card)
        }
      }
    }
    .padding(TBDKit.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  /// "Safari · 30 min", or "30 min" when Companion saw no app.
  static func detail(_ card: FlowDayCard) -> String {
    let apps = FlowDayModel.appsText(card.evidence)
    let minutes = FlowDayModel.minutesText(card.minutes)
    return apps.isEmpty ? minutes : apps + " · " + minutes
  }
}

// MARK: - Plan vs actual tab

struct FlowPlanVsActualView: View {
  @ObservedObject var model: FlowDayModel

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      if !model.snapshot.hasPlan {
        VStack(alignment: .leading, spacing: TBDKit.s1) {
          Text("No tasks for today").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
          Text("Add tasks on the Today tab. Then TBD compares them with your timeline here.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .padding(.vertical, TBDKit.s5)
      } else {
        FlowDayStripCard(model: model)
        if model.snapshot.cards.isEmpty {
          Text("No finished timeline cards yet today. They show here when Companion has written them.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        } else {
          VStack(alignment: .leading, spacing: TBDKit.s2) {
            ForEach(model.snapshot.cards) { cardRow($0) }
          }
        }
      }
    }
  }

  private func cardRow(_ card: FlowDayCard) -> some View {
    HStack(alignment: .top, spacing: TBDKit.s4) {
      Rectangle().fill(card.kind.fill).frame(width: 6, height: 44)
        .overlay(Rectangle().strokeBorder(TBDColor.lineStrong, lineWidth: 1))
        .accessibilityHidden(true)
      Text(FlowDayModel.range(card.evidence)).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        .frame(width: 130, alignment: .leading)
      VStack(alignment: .leading, spacing: TBDKit.s1) {
        Text(card.evidence.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).lineLimit(2)
        let apps = FlowDayModel.appsText(card.evidence)
        if !apps.isEmpty { Text(apps).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1) }
      }
      Spacer(minLength: 0)
      VStack(alignment: .trailing, spacing: TBDKit.s1) {
        TBDTag(card.tagText, status: card.kind.tagStatus)
        if let source = model.provenance(card) {
          Text(source).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
      }
      FlowCardMenuButton(model: model, card: card)
    }
    .padding(TBDKit.s3)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    .accessibilityElement(children: .contain)
  }
}
