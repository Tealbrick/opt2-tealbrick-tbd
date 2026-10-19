//
//  FlowObserverView.swift
//  TBD
//
//  Flow › Observer: the switch "Watch my screen for focus" (off until turned on), how TBD looks at the screen (text only
//  on this Mac, screenshots on this Mac, or a cloud model the person chooses), the nudge style and today's counters.
//  Layout follows the approved mockup (coordination/leads/tbd/flow-mockups-20261019, "observer").
//

import SwiftUI
import TBDDesign
import TBDModels

/// The state behind the page: the observer setup, Ollama's installed models and the saved connections.
@MainActor
final class FlowObserverModel: ObservableObject {
  let setup: TBDFlowObserverSetup
  private let installedModels: () async -> [String]?
  private let reconfigure: @MainActor () -> Void

  @Published var selection: TBDFlowObserverMode
  @Published private(set) var watching: Bool
  /// nil until Ollama answered; empty = running with no model; nil after a failed load = not running.
  @Published private(set) var installed: [String]?
  @Published private(set) var ollamaChecked = false
  @Published var textModel: String
  @Published var visionModel: String
  @Published private(set) var connections: [TBDModelConnection] = []
  @Published var cloudConnectionID: String
  @Published var cloudModel: String
  @Published private(set) var error: String?
  /// What the observer would do now ("Set up a model…") when the switch is on and it cannot run.
  @Published private(set) var problem: String?

  init(
    setup: TBDFlowObserverSetup = TBDFlowObserverSetup(),
    installedModels: @escaping () async -> [String]? = { await TBDFlowObserverSetup.installedModels() },
    reconfigure: @escaping @MainActor () -> Void = { FlowDistractionAgent.shared.reconfigure() }
  ) {
    self.setup = setup
    self.installedModels = installedModels
    self.reconfigure = reconfigure
    selection = setup.mode
    watching = setup.watching
    textModel = setup.rememberedModel(for: .textLocal) ?? ""
    visionModel = setup.rememberedModel(for: .visionLocal) ?? TBDFlowObserverSetup.defaultVisionModel
    let current = setup.currentRoute()
    let isCloud = setup.mode == .cloud
    cloudConnectionID = isCloud ? (current?.connection.id ?? "") : ""
    cloudModel = isCloud ? (current?.model ?? "") : ""
    refreshProblem()
  }

  /// Reads Ollama's model list and the saved connections.
  func reload() async {
    let names = await installedModels()
    installed = names
    ollamaChecked = true
    connections = setup.connections()
    if textModel.isEmpty, let names, let first = setup.defaultTextModel(installed: names) { textModel = first }
    if cloudConnectionID.isEmpty, let first = connections.first(where: { !isLoopback($0) }) { cloudConnectionID = first.id }
    refreshProblem()
  }

  private func isLoopback(_ connection: TBDModelConnection) -> Bool {
    guard let host = URL(string: connection.endpoint)?.host else { return false }
    return ["localhost", "127.0.0.1", "::1"].contains(host)
  }

  /// A model download finished: read Ollama again and let the observer check its route.
  func downloadFinished() {
    Task {
      await reload()
      reconfigure()
    }
  }

  func setWatching(_ on: Bool) {
    setup.watching = on
    watching = on
    refreshProblem()
    reconfigure()
  }

  /// A tap on a choice. The local choices apply at once; the cloud choice opens its form (the consent is the button).
  func choose(_ mode: TBDFlowObserverMode) {
    error = nil
    selection = mode
    switch mode {
    case .textLocal:
      let model = textModel.isEmpty ? (setup.defaultTextModel(installed: installed ?? []) ?? "") : textModel
      guard !model.isEmpty else {
        setup.mode = .textLocal
        error = "No model found in Ollama. Download one in Ollama, then open this page again."
        refreshProblem()
        return
      }
      textModel = model
      applyLocal(.textLocal, model: model)
    case .visionLocal:
      let model = visionModel.isEmpty ? TBDFlowObserverSetup.defaultVisionModel : visionModel
      visionModel = model
      applyLocal(.visionLocal, model: model)
    case .cloud:
      break
    }
  }

  func pickLocalModel(_ mode: TBDFlowObserverMode, _ model: String) {
    if mode == .textLocal { textModel = model } else { visionModel = model }
    applyLocal(mode, model: model)
  }

  private func applyLocal(_ mode: TBDFlowObserverMode, model: String) {
    do { try setup.chooseLocal(mode, model: model) } catch { self.error = error.localizedDescription }
    refreshProblem()
    reconfigure()
  }

  /// The person's tap on "Use this model" in the cloud choice: the consent and the route.
  func chooseCloud() {
    error = nil
    do {
      try setup.chooseCloud(connectionID: cloudConnectionID, model: cloudModel)
    } catch {
      self.error = "Choose a saved connection and enter a model ID. Add connections in Settings › Models."
    }
    refreshProblem()
    reconfigure()
  }

  var cloudInUse: Bool { setup.mode == .cloud && setup.cloudConsentAt != nil && setup.cloudConsentConnectionID == cloudConnectionID }

  var cloudProvider: String {
    connections.first { $0.id == cloudConnectionID }.map(TBDFlowObserverSetup.providerName) ?? "the cloud provider"
  }

  /// Vision download state for the offered model.
  func visionInstalled() -> Bool? {
    installed.map { TBDAgentModelSetup.localModelPresent(visionModel, in: $0) }
  }

  func refreshProblem() {
    guard watching else { problem = nil; return }
    do { _ = try setup.resolve(); problem = nil } catch { problem = error.localizedDescription }
  }
}

struct FlowObserverView: View {
  @ObservedObject var observer: FlowDistractionAgent
  @ObservedObject var model: FlowObserverModel
  @ObservedObject private var settings = FlowAgentSettings.shared
  @ObservedObject private var downloads = TBDLocalModelDownload.shared
  var mirror: FlowSessionMirror = .shared

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: TBDKit.s6) {
        leftColumn.frame(maxWidth: .infinity, alignment: .leading)
        rightColumn.frame(width: 340)
      }
      .frame(minWidth: 760)
      VStack(alignment: .leading, spacing: TBDKit.s5) {
        leftColumn
        rightColumn
      }
    }
    .task {
      await model.reload()
      observer.refreshCounters()
    }
  }

  // MARK: Left

  private var leftColumn: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      card {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: TBDKit.s1) {
            Text("Watch my screen for focus").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("Every 15 seconds TBD checks if you work on your plan, and nudges you when you drift.")
              .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 0)
          Toggle(isOn: Binding(get: { model.watching }, set: { model.setWatching($0) })) { EmptyView() }
            .toggleStyle(TBDSwitchStyle()).accessibilityLabel("Watch my screen for focus")
        }
        if let problem = model.problem {
          Text(problem).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn)
            .fixedSize(horizontal: false, vertical: true)
        } else if model.watching, let error = observer.lastError {
          Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Text("How TBD looks at your screen").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
      textChoice
      visionChoice
      cloudChoice
      if let error = model.error {
        Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var textChoice: some View {
    let selected = model.selection == .textLocal
    let name = model.textModel.isEmpty ? "a model" : model.textModel
    return choice(
      "Text only, on this Mac",
      detail: "TBD reads the text on your screen and asks the model on this Mac (\(name)). Nothing leaves your Mac.",
      selected: selected, tag: "Recommended", tagStatus: .live, mode: .textLocal
    ) {
      if selected { localModelPicker(.textLocal) }
    }
  }

  private var visionChoice: some View {
    let selected = model.selection == .visionLocal
    return choice(
      "Screenshots, on this Mac",
      detail:
        "A vision model on this Mac looks at the screenshot. Needs a \(TBDFlowObserverSetup.visionDownloadSize) download (\(TBDFlowObserverSetup.defaultVisionModel)).",
      selected: selected, tag: nil, tagStatus: .idle, mode: .visionLocal
    ) {
      if selected {
        localModelPicker(.visionLocal)
        visionDownload
      }
    }
  }

  @ViewBuilder
  private func localModelPicker(_ mode: TBDFlowObserverMode) -> some View {
    let current = mode == .textLocal ? model.textModel : model.visionModel
    if !model.ollamaChecked {
      Text("Looking for Ollama…").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    } else if let names = model.installed {
      let options = Self.pickerOptions(names: names, current: current)
      if options.isEmpty {
        Text("Ollama has no model yet.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else {
        TBDSelect("Model", selection: Binding(get: { current }, set: { model.pickLocalModel(mode, $0) }), options: options)
          .frame(maxWidth: 360)
      }
    } else {
      Text("Ollama is not running on this Mac. Open Ollama, then open this page again.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The installed models, with the chosen one first when it is not downloaded (so the picker shows it).
  static func pickerOptions(names: [String], current: String) -> [(String, String)] {
    var options = names.map { ($0, $0) }
    if !current.isEmpty, !names.contains(current) { options.insert((current, current + " (not downloaded)"), at: 0) }
    return options
  }

  @ViewBuilder
  private var visionDownload: some View {
    let name = model.visionModel
    if let progress = downloads.progress[name] {
      Text("Downloading \(name): \(Int(progress * 100)) %").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.inkSoft)
    } else if model.visionInstalled() == false {
      HStack(spacing: TBDKit.s3) {
        Button("Download \(name) (\(TBDFlowObserverSetup.visionDownloadSize))") {
          downloads.pull(name) { model.downloadFinished() }
        }
        .buttonStyle(TBDButtonStyle(.secondary))
      }
      if let failure = downloads.errors[name] {
        Text(failure).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.statusNeedsYouOn).fixedSize(horizontal: false, vertical: true)
      }
    } else if model.visionInstalled() == true {
      Text("\(name) is downloaded.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
  }

  private var cloudChoice: some View {
    let selected = model.selection == .cloud
    let detail = TBDFlowObserverSetup.consentSentence(provider: selected ? model.cloudProvider : "your cloud provider")
    return choice("Cloud model", detail: detail, selected: selected, tag: "Leaves this Mac", tagStatus: .needsYou, mode: .cloud) {
      if selected {
        if model.connections.isEmpty {
          Text("No saved connection. Add one in Settings › Models, then open this page again.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
        } else {
          TBDSelect(
            "Connection", selection: $model.cloudConnectionID,
            options: [("", "Choose a connection")] + model.connections.map { ($0.id, $0.name) }
          )
          .frame(maxWidth: 360)
          TBDField("Model ID", text: $model.cloudModel, prompt: "claude-opus-5-5").frame(maxWidth: 360)
          HStack(spacing: TBDKit.s3) {
            Button(model.cloudInUse ? "In use" : "Use this model") { model.chooseCloud() }
              .buttonStyle(TBDButtonStyle(.secondary))
              .disabled(model.cloudConnectionID.isEmpty || model.cloudModel.trimmingCharacters(in: .whitespaces).isEmpty || model.cloudInUse)
            if !model.cloudInUse {
              Text("Not in use until you press this.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
          }
        }
      }
    }
  }

  private func choice<Extra: View>(
    _ title: String, detail: String, selected: Bool, tag: String?, tagStatus: TBDStatus, mode: TBDFlowObserverMode,
    @ViewBuilder extra: () -> Extra
  ) -> some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Button { model.choose(mode) } label: {
        HStack(alignment: .top, spacing: TBDKit.s3) {
          Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(selected ? TBDColor.tealInk : TBDColor.muted).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: TBDKit.s1) {
            HStack(spacing: TBDKit.s2) {
              Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
              if let tag { TBDTag(tag, status: tagStatus) }
            }
            Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
              .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityAddTraits(selected ? .isSelected : [])
      extra().padding(.leading, TBDKit.s6)
    }
    .padding(TBDKit.s4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? TBDColor.tealWash : TBDColor.paper, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(selected ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair))
  }

  // MARK: Right

  private var rightColumn: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      card {
        Text("Nudges").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        Text("How often").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        TBDSegmented(
          selection: Binding(get: { settings.alertStyle }, set: { setAlertStyle($0) }),
          options: [(FlowAlertStyle.quiet, "Quiet"), (.friendly, "Friendly"), (.feisty, "Feisty")])
        Text("Where").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        TBDSegmented(
          selection: $settings.nudgeVariant, options: [(FlowNudgeVariant.side, "Side"), (.top, "Top"), (.peek, "Peek")])
        Button("Show a test nudge") { mirror.debugNudge(variant: settings.nudgeVariant) }.buttonStyle(TBDButtonStyle(.secondary))
      }
      card {
        Text("Today").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted)
        Text(observer.counters.summary).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
        Text("Screen text and screenshots are not stored. Only the verdicts are kept for today.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// Saves the style and puts it into the running session at once.
  private func setAlertStyle(_ style: FlowAlertStyle) {
    settings.alertStyle = style
    FlowPlanner.shared.refresh()
  }

  private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: TBDKit.s3, content: content)
      .padding(TBDKit.s4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}
