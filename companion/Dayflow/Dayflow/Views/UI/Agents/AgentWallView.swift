//
//  AgentWallView.swift
//  TBD
//
//  The Agents page (dev.15, WP-WALL, C280 C4, C127): the v1 brick wall, back as a read-only roster wall. One brick per
//  agent of the workspace, TBD's own agent first. Layout and states follow the approved mockups
//  (coordination/leads/tbd/wall-mockups-20261020, "wall-restored" and "wall-restored-empty"). Behaviour follows v1:
//  the wall scrolls by itself (16 pt/s), freezes while the pointer is on it, a drag scrubs it, a hover card names the
//  agent and a click selects it (deep teal brick, highlighted list row). Reduce Motion stops the automatic scroll.
//  The page only reads the roster (`AgentWallRosterStore`); it starts no process and changes nothing in the workspace.
//

import AppKit
import SwiftUI
import TBDDesign

struct AgentWallView: View {
  @ObservedObject private var store: AgentWallRosterStore
  @AppStorage("agentWallShowOffline") private var showOffline = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selectedID: String?
  @State private var hoverPoint: CGPoint?
  @State private var scroll = AgentWallScroll()
  /// Design shots: the wall does not move.
  private let frozen: Bool

  static let headerHeight: CGFloat = 84
  static let sideInset: CGFloat = 32

  @MainActor
  init(store: AgentWallRosterStore? = nil, frozen: Bool = false) {
    _store = ObservedObject(wrappedValue: store ?? .shared)
    self.frozen = frozen
  }

  var body: some View {
    GeometryReader { geo in
      let state = store.state
      let agents = state.visible(showOffline: showOffline)
      let plan = AgentWallPlan(agents: state.agents, showOffline: showOffline)
      let selected = AgentWallSelection.valid(selectedID, in: agents)
      let notice = state.notice
      // Everything fits one screen: the wall takes what is left after header, callouts and cards. A small window scrolls.
      let cardsHeight: CGFloat = state.mode == .roster ? min(320, max(240, geo.size.height * 0.31)) : 190
      let noticeHeight: CGFloat = notice.map { ($0.text.count > 90 ? 80 : 54) + TBDTokens.Space.lg } ?? 0
      let chrome: CGFloat = 16 + Self.headerHeight + cardsHeight + noticeHeight + 2 * TBDTokens.Space.lg + 16
      let wallHeight = min(360, max(150, geo.size.height - chrome - 2 * AgentWallGeometry.calloutZone))
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: TBDTokens.Space.lg) {
          TBDPageHeader("Agents", label: "Your workspace")
            .padding(.horizontal, Self.sideInset).frame(height: Self.headerHeight, alignment: .top)
          wallBand(plan: plan, selected: selected, agents: agents, width: geo.size.width, wallHeight: wallHeight)
          if let notice { noticeRow(notice).padding(.horizontal, Self.sideInset) }
          HStack(alignment: .top, spacing: TBDTokens.Space.lg) {
            summary(state).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .tbdCard(padding: TBDTokens.Space.lg)
            list(agents, selected: selected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .tbdCard(padding: TBDTokens.Space.lg)
            legend.frame(width: 250).frame(maxHeight: .infinity, alignment: .topLeading).tbdCard(padding: TBDTokens.Space.lg)
          }
          .frame(height: cardsHeight)
          .padding(.horizontal, Self.sideInset)
        }
        .padding(.vertical, 16)
        .frame(width: geo.size.width, alignment: .top)
        .frame(minHeight: geo.size.height, alignment: .top)
      }
    }
    .onAppear { store.pageDidAppear() }
    .onDisappear { store.pageDidDisappear() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.appDidBecomeActive()
    }
  }

  // MARK: Wall band (hero)

  /// The first slot sits 100 pt from the left edge at the start and in the frozen shots.
  private func anchorShift(_ wallHeight: CGFloat) -> Double {
    let slot = AgentWallPlan.slot(0)
    return 100 - AgentWallPlan.x(course: slot.course, column: slot.column) * Double(wallHeight / CGFloat(AgentWallTile.height))
  }

  private func currentShift(_ now: Date, wallHeight: CGFloat) -> Double {
    anchorShift(wallHeight) + (frozen ? 0 : scroll.shift(at: now, reduceMotion: reduceMotion))
  }

  private func wallBand(plan: AgentWallPlan, selected: String?, agents: [WallAgent], width: CGFloat, wallHeight: CGFloat) -> some View {
    let total = AgentWallGeometry.calloutZone * 2 + wallHeight
    return TimelineView(.animation(paused: frozen || !scroll.isMoving(reduceMotion: reduceMotion))) { timeline in
      let shift = currentShift(timeline.date, wallHeight: wallHeight)
      AgentWallBand(plan: plan, selectedID: selected, width: width, wallHeight: wallHeight, shift: shift)
        .overlay(alignment: .topLeading) {
          if let point = hoverPoint,
            let brick = AgentWallGeometry(plan: plan, width: width, wallHeight: wallHeight, shift: shift).brick(at: point),
            let agent = agents.first(where: { $0.id == brick.agentID })
          {
            hoverCard(agent).offset(x: min(point.x + 16, width - 280), y: max(0, point.y - 110)).allowsHitTesting(false)
          }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
          switch phase {
          case .active(let point):
            scroll.hoverMoved(at: Date(), reduceMotion: reduceMotion)
            hoverPoint = scroll.dragStart == nil ? point : nil
          case .ended:
            scroll.hoverEnded(at: Date())
            hoverPoint = nil
          }
        }
        .gesture(
          DragGesture(minimumDistance: 4)
            .onChanged { value in
              scroll.dragChanged(translation: value.translation.width, at: Date(), reduceMotion: reduceMotion)
              hoverPoint = nil
            }
            .onEnded { _ in scroll.dragEnded(at: Date()) }
        )
        .onTapGesture { location in
          let geometry = AgentWallGeometry(
            plan: plan, width: width, wallHeight: wallHeight, shift: currentShift(Date(), wallHeight: wallHeight))
          selectedID = AgentWallSelection.toggled(current: selected, hit: geometry.brick(at: location)?.agentID)
        }
    }
    .frame(height: total)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Brick wall with one brick for each agent of your workspace. The list below has the same agents.")
  }

  private func hoverCard(_ agent: WallAgent) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(agent.name).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.ink).lineLimit(2)
      if !agent.purpose.isEmpty { Text(agent.purpose).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).lineLimit(2) }
      Text([agent.harness, agent.state.rawValue].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted)
      Text("Click to select").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
    .padding(12).frame(width: 260, alignment: .leading).tbdFloating()
  }

  // MARK: Notice

  private func noticeRow(_ notice: AgentWallNotice) -> some View {
    HStack(alignment: .center, spacing: TBDTokens.Space.md) {
      TBDNotice(notice.text, tone: notice.needsYou ? .needsYou : .neutral)
      if notice.offersAccount {
        Button("Account settings") {
          NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: "account")
        }
        .buttonStyle(TBDButtonStyle(.secondary))
      }
    }
  }

  // MARK: Cards

  private func metric(_ value: String, _ label: String, color: Color? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(TBDFonts.nunito(TBDKit.textTitle, TBDKit.weightLabel)).monospacedDigit().foregroundStyle(color ?? TBDColor.ink)
      Text(label).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
  }

  /// TBD counts: it is an agent on the wall and in the list, so the numbers match the rows. Offline agents are counted
  /// even when the toggle hides them.
  private func summary(_ state: AgentWallState) -> some View {
    let counts = state.counts
    return VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
      TBDLabel("Agents on the wall")
      Text("\(counts.total)").font(TBDFonts.nunito(TBDKit.textNumeral, TBDKit.weightHead)).tracking(-1).foregroundStyle(TBDColor.ink)
      HStack(spacing: TBDTokens.Space.xl) {
        metric("\(counts.online)", "online")
        metric("\(counts.paused)", "paused", color: counts.paused > 0 ? TBDColor.brickInk : nil)
        metric("\(counts.offline)", "offline")
      }
      Text("TBD, your own agent, is one of them. It is always on the wall.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
  }

  private func tag(_ agent: WallAgent) -> TBDTag {
    switch agent.state {
    case .online: return TBDTag("Online", status: .live)
    case .paused: return TBDTag("Paused", status: .needsYou)
    case .offline: return TBDTag("Offline", status: .idle)
    }
  }

  private func swatch(_ photo: AgentWallPhoto, width: CGFloat = 22, height: CGFloat = 8) -> some View {
    Group {
      if let image = AgentWallSwatches.image(photo) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: width, height: height)
          .clipShape(RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)).unredacted()
      } else {
        Rectangle().fill(TBDColor.plate).frame(width: width, height: height)
      }
    }
    .accessibilityHidden(true)
  }

  private func list(_ agents: [WallAgent], selected: String?) -> some View {
    VStack(alignment: .leading, spacing: TBDTokens.Space.sm) {
      HStack {
        TBDLabel("Agents")
        Spacer()
        if selected != nil { Button("Clear") { selectedID = nil }.buttonStyle(TBDButtonStyle(.quiet)) }
      }
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(agents) { agent in
            let on = agent.id == selected
            Button { selectedID = AgentWallSelection.toggled(current: selected, hit: agent.id) } label: {
              HStack(spacing: 10) {
                swatch(on ? .deep : agent.tone.photo ?? .red)
                Text(agent.name).font(TBDFonts.nunito(TBDKit.textHint, TBDKit.weightLabel)).foregroundStyle(TBDColor.ink).lineLimit(1)
                Text(agent.purpose).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text(agent.harness).font(TBDFonts.mono(10)).foregroundStyle(TBDColor.muted).lineLimit(1)
                tag(agent)
              }
              .padding(.horizontal, 6)
              .background(on ? TBDColor.tealWash : Color.clear, in: TBDBrickShape())
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Selects this agent on the wall")
            .accessibilityAddTraits(on ? .isSelected : [])
          }
        }
      }
    }
  }

  private func legendRow(_ photo: AgentWallPhoto, _ label: String) -> some View {
    HStack(spacing: 10) {
      swatch(photo, width: 26, height: 10)
      Text(label).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
    }
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: 5) {
      TBDLabel("One brick · one agent")
      legendRow(.teal, "Online")
      legendRow(.amber, "Paused")
      legendRow(.red, "Offline · plain wall")
      legendRow(.deep, "TBD · your own agent")
      Toggle("Show offline agents", isOn: $showOffline).toggleStyle(TBDSwitchStyle())
    }
  }
}
