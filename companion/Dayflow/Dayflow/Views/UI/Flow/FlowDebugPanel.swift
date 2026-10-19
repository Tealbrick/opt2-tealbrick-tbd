//
//  FlowDebugPanel.swift
//  TBD
//
//  The tuning card on Flow › Nudge preview: every knob in `FlowAgentSettings` plus buttons that bring the creature in
//  on demand (side / top / peek), so the companion can be tuned without rebuilding. Port of v1 with the TBD kit
//  instead of the dark overlay, and without the model and reasoning controls. The agent log and the prompt preview
//  come back with the observer (slice F3).
//

import SwiftUI
import TBDDesign

struct FlowDebugPanel: View {
  @ObservedObject private var settings = FlowAgentSettings.shared
  @ObservedObject private var mirror = FlowSessionMirror.shared
  @ObservedObject private var timeline = FlowSessionTimeline.shared
  @State private var isOpen: Bool
  @State private var tab: Tab = .overlay
  @State private var toastText = "Nice streak — keep it up!"

  init(startsOpen: Bool = false) { _isOpen = State(initialValue: startsOpen) }

  private enum Tab: String, CaseIterable {
    case overlay = "Overlay"
    case agent = "Observer"
    case prompt = "Prompt"
    case timeline = "Timeline"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack {
        Text("Debug").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
        Spacer(minLength: 0)
        Button(isOpen ? "Hide debug" : "Show debug") { isOpen.toggle() }.buttonStyle(TBDButtonStyle(.quiet))
      }
      if isOpen {
        TBDSegmented(selection: $tab, options: Tab.allCases.map { ($0, $0.rawValue) })
        switch tab {
        case .overlay: overlayForm
        case .agent: agentForm
        case .prompt: promptForm
        case .timeline: timelineList
        }
      } else {
        Text("Overlay timing, how the observer looks at the screen, the prompt and the session timeline.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
    }
    .padding(TBDKit.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }

  // MARK: Observer settings

  private var agentForm: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Toggle(isOn: $settings.agentEnabled) { text("Watch the screen during sessions") }.toggleStyle(TBDSwitchStyle())
      slider("Every \(Int(settings.tickSeconds)) s", value: $settings.tickSeconds, in: 5...120, step: 5)
      slider(
        "Timeline every \(Int(settings.timelineEverySeconds)) s", value: $settings.timelineEverySeconds, in: 15...300, step: 15)
      row("Screenshot") {
        TBDSegmented(
          selection: $settings.screenshotHeight, options: FlowAgentSettings.screenshotHeights.map { ($0, "\($0)p") })
      }
      slider(String(format: "JPEG quality %.2f", settings.jpegQuality), value: $settings.jpegQuality, in: 0.3...0.95, step: 0.05)
      Toggle(isOn: $settings.textOnly) { text("Text only (send the screen's text instead of the image)") }.toggleStyle(TBDSwitchStyle())
      slider("Timeout \(Int(settings.tickTimeoutSeconds)) s", value: $settings.tickTimeoutSeconds, in: 10...180, step: 5)
      Stepper(value: $settings.maxFailures, in: 1...20) { text("Give up after \(settings.maxFailures) failed checks") }
      hint("Changes apply to the next session the observer starts.")
      Button("Reset to defaults") { settings.resetToDefaults() }.buttonStyle(TBDButtonStyle(.quiet))
    }
  }

  // MARK: Prompt

  private var promptForm: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack {
        text("Briefing template").font(TBDTokens.Typography.label)
        Spacer(minLength: 0)
        Button("Use built-in") { settings.briefingTemplate = "" }.buttonStyle(TBDButtonStyle(.quiet))
      }
      FlowTextArea(text: $settings.briefingTemplate, height: 120, monospaced: true)
      hint("Empty means the built-in briefing.")
      text("Extra instructions (appended)").font(TBDTokens.Typography.label)
      FlowTextArea(text: $settings.extraInstructions, height: 70, monospaced: true)
      hint("Prompt changes apply to the next session the observer starts.")
    }
  }

  // MARK: Overlay

  private var overlayForm: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      row("Nudge layout") {
        TBDSegmented(selection: $settings.nudgeVariant, options: FlowNudgeVariant.allCases.map { ($0, $0.title) })
      }
      text("Trigger now").font(TBDTokens.Typography.label)
      HStack(spacing: TBDKit.s2) {
        Button("Nudge from side") { mirror.debugNudge(variant: .side) }
        Button("Drop from top") { mirror.debugNudge(variant: .top) }
        Button("Peek from top") { mirror.debugNudge(variant: .peek) }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      HStack(spacing: TBDKit.s2) {
        Button("Escalated (fire)") { mirror.debugNudge(variant: .side, escalated: true) }
        Button("Break tub") { mirror.debugBreak() }
        Button("Dismiss") { mirror.debugHideOverlay() }
        Button("Simulate distraction (⌘⇧D)") { mirror.simulateDistraction() }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      HStack(spacing: TBDKit.s2) {
        TBDField("Toast text", text: $toastText)
        Button("Show toast") { mirror.debugToast(toastText) }.buttonStyle(TBDButtonStyle(.secondary))
      }
      slider("Break tub stays \(Int(settings.breakOverlaySeconds)) s", value: $settings.breakOverlaySeconds, in: 2...60, step: 1)
      slider("Toasts stay \(Int(settings.toastSeconds)) s", value: $settings.toastSeconds, in: 1...20, step: 1)
      slider("Praise stays \(Int(settings.praiseSeconds)) s", value: $settings.praiseSeconds, in: 1...20, step: 1)
      HStack(spacing: TBDKit.s2) {
        Text(
          String(
            format: "Drag offsets: side %.0f · top %.0f · peek %.0f", settings.sideOffsetY, settings.topOffsetX,
            settings.peekOffsetX)
        )
        .font(TBDTokens.Typography.mono).foregroundStyle(TBDColor.muted)
        Button("Reset positions") {
          settings.resetPositions()
          FlowOverlayController.shared.repositionIfVisible()
        }.buttonStyle(TBDButtonStyle(.quiet))
      }
      hint(
        "Hover the creature to reveal its bubble and replies. Drag it to move where it comes from (side: up and down, top layouts: left and right). Simulate distraction needs an active session; the trigger buttons work any time."
      )
    }
  }

  // MARK: Timeline

  /// The activity timeline the observer is building for the session summary (what the JSON file holds right now).
  private var timelineList: some View {
    VStack(alignment: .leading, spacing: TBDKit.s2) {
      HStack(spacing: TBDKit.s2) {
        Text(verbatim: timeline.fileURL.path).font(TBDTokens.Typography.mono).foregroundStyle(TBDColor.muted)
          .lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 0)
        if let at = timeline.updatedAt {
          Text(verbatim: "updated " + at.formatted(.dateTime.hour().minute().second()))
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([timeline.fileURL]) }
          .buttonStyle(TBDButtonStyle(.quiet))
      }
      if timeline.entries.isEmpty {
        hint(
          "No timeline yet. The model writes one about every \(Int(settings.timelineEverySeconds)) s of a session (\(timeline.observations.count) checks logged so far)."
        )
      }
      ForEach(timeline.entries) { entry in
        HStack(alignment: .center, spacing: TBDKit.s2) {
          Text(
            verbatim: entry.startedAt.formatted(.dateTime.hour().minute()) + "–" + entry.endedAt.formatted(.dateTime.hour().minute())
          )
          .font(TBDTokens.Typography.mono).foregroundStyle(TBDColor.muted).frame(width: 110, alignment: .leading)
          Rectangle().fill(timelineColor(entry.kind)).frame(width: 6, height: 14)
          text(entry.title)
          Spacer(minLength: 0)
          Text(verbatim: Self.duration(entry.endedAt.timeIntervalSince(entry.startedAt)))
            .font(TBDTokens.Typography.mono).foregroundStyle(TBDColor.muted)
        }
      }
    }
  }

  private func timelineColor(_ kind: FlowSessionTimeline.Kind) -> Color {
    switch kind {
    case .focused: return TBDColor.teal
    case .distracted: return TBDColor.brick
    case .break: return TBDColor.toneStone
    }
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    return total >= 60 ? "\(total / 60)m \(total % 60)s" : "\(total)s"
  }

  // MARK: Bits

  private func text(_ value: String) -> Text {
    Text(value).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
  }

  private func hint(_ value: String) -> some View {
    Text(value).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
  }

  private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: TBDKit.s3) {
      text(label).frame(width: 110, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
  }

  private func slider(_ label: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
    HStack(spacing: TBDKit.s3) {
      text(label).frame(width: 220, alignment: .leading)
      Slider(value: value, in: range, step: step).tint(TBDColor.tealInk)
    }
  }
}
