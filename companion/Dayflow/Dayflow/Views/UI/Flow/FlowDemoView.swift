//
//  FlowDemoView.swift
//  TBD
//
//  Flow › Nudge preview: try the creature's nudges, break tub and timers on your own screen. Nothing here detects real
//  distraction or touches your task list. The debug panel below holds the tuning knobs.
//

import SwiftUI
import TBDDesign
import TBDModels

struct FlowDemoView: View {
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @State private var tasks = "[Demo] Review today's priorities\n[Demo] Draft the proposal\n[Demo] Take a short break"
  var showsDebugOpen = false

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Try TBD's nudges and timers on your own screen. Nothing here detects real distraction or creates tasks.")
        .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: TBDKit.s6) {
          sessionCard.frame(maxWidth: .infinity, alignment: .leading)
          nudgeCard.frame(width: 340)
        }
        .frame(minWidth: 760)
        VStack(alignment: .leading, spacing: TBDKit.s5) {
          sessionCard
          nudgeCard
        }
      }
      FlowDebugPanel(startsOpen: showsDebugOpen)
    }
  }

  private var sessionCard: some View {
    card {
      HStack {
        Text("Demo session").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        Spacer(minLength: 0)
        TBDTag(mirror.snapshot.phase.rawValue.capitalized, status: mirror.snapshot.phase == .idle ? .idle : .live)
      }
      FlowTextArea(text: $tasks, height: 110)
      Text("One demo task per line.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      HStack(spacing: TBDKit.s2) {
        Button("Start 1-minute demo") { startDemo() }.buttonStyle(TBDButtonStyle(.primary))
        Button("Stop") {
          mirror.apply(.idle)
          mirror.debugHideOverlay()
        }.buttonStyle(TBDButtonStyle(.secondary))
      }
    }
  }

  private var nudgeCard: some View {
    card {
      Text("Show a nudge").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: TBDKit.s2), GridItem(.flexible(), spacing: TBDKit.s2)],
        alignment: .leading, spacing: TBDKit.s2
      ) {
        Button("Side nudge") { mirror.debugNudge(variant: .side) }
        Button("Top nudge") { mirror.debugNudge(variant: .top) }
        Button("Escalated") { mirror.debugNudge(variant: .side, escalated: true) }
        Button("Break") { mirror.debugBreak() }
        Button("Task reminder") { mirror.debugToast("Demo: switch focus to drafting the proposal.") }
        Button("Dismiss") { mirror.debugHideOverlay() }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
    }
  }

  private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: TBDKit.s3, content: content)
      .padding(TBDKit.s4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  /// A one-minute session on the demo goals (v1 FlowDemoView). It does not touch the task list.
  private func startDemo() {
    var snapshot = FlowNativeSnapshot()
    let start = Int(Date().timeIntervalSince1970)
    snapshot.phase = .active
    snapshot.alertStyle = .friendly
    snapshot.sessionStartedAt = start
    snapshot.sessionEndsAt = start + 60
    snapshot.goals = tasks.split(separator: "\n").map(String.init).enumerated().map {
      TBDFlowGoal(id: "local-demo-\($0.offset)", title: $0.element)
    }
    mirror.apply(snapshot)
  }
}
