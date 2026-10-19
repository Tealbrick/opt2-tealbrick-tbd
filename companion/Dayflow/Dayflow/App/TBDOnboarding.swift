import AppKit
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels

/// Opens the first-launch flow at a step: post with the step's raw value ("portal", "agent", "permissions",
/// "models", "summary"). Used by the missing-dependency links in the app and in TBDListening.
extension Notification.Name {
  static let tbdOpenOnboarding = Notification.Name("tbdOpenOnboarding")
}

/// First-launch onboarding (WP-ONB, C285 STREAMLINE, C286; spec coordination/leads/tbd/ONBOARDING-SPEC.md).
/// The rules live in `TBDOnboardingMachine` (TBDModels); this controller reads the real dependencies every 2 s while
/// the flow is visible, runs the step actions and the Screen recording self-relaunch.
@MainActor
final class TBDOnboardingController: ObservableObject {
  static let shared = TBDOnboardingController()

  @Published private(set) var machine: TBDOnboardingMachine
  @Published private(set) var checks = TBDOnboardingChecks()
  @Published private(set) var isShowing: Bool

  // Step 2: TBD's agent model (API key or Ollama on this Mac; no subscription for the Agent SDK, C287).
  @Published var agentRuntime: TBDOnboardingRuntime = .local
  @Published var agentModel = TBDAgentModelSetup.defaultLocalModel
  @Published var agentKey = ""
  @Published private(set) var agentTest: String?
  @Published private(set) var agentTestOK = false
  @Published private(set) var agentTesting = false
  @Published private(set) var pairCode = ""
  @Published private(set) var pairing = false
  @Published private(set) var pairError = ""
  /// Ollama on this Mac: status for the agent's model (after a test) and for the Companion's recommended model.
  @Published private(set) var agentLocalStatus: TBDAgentModelSetup.LocalStatus?
  @Published private(set) var companionLocalStatus: TBDAgentModelSetup.LocalStatus?
  let downloads = TBDLocalModelDownload.shared
  /// The Companion's recommended local model (Qwen3-VL 4B, the preset the Settings upgrade sheet uses).
  let companionLocalModel = LocalModelPreset.recommended.modelId(for: .ollama)
  // Step 3: set once the person asked macOS for Screen recording in this run; then the relaunch button shows.
  @Published private(set) var screenRequested = false

  let account = TBDAccountCoordinator.shared
  let permissions = TBDPermissions.shared
  let speech = TBDSpeechModelSetup.shared
  /// Built when the flow first needs it (not at every launch of a finished install, review dev.9 #6).
  private(set) lazy var providers = ProvidersSettingsViewModel()
  private let registry = TBDModelRegistry()
  private var poll: Task<Void, Never>?
  /// resolve() reads the agent's key from the Keychain: only when due (step change to Agent/Summary, after
  /// "Test and save", on open), never on the 2 s timer (review dev.9 #6).
  private var agentCheckDue = true
  /// One relaunch at a time (review dev.9 #4).
  private var relaunching = false
  private var linkObserver: NSObjectProtocol?
  /// A design-shots preview: fixed state, no polling, no links.
  private let isPreview: Bool
  /// The XCTest host (DayflowTests). The checks start the Chat helper, which reads its Keychain key on the main
  /// thread; a rebuilt ad-hoc test host is not on that item's access list, so macOS asks for the login password and
  /// the host hangs before the test runner connects (seen 2026-10-19). Tests drive the state in TBDModels instead.
  static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  private init(store: TBDOnboardingStore = TBDOnboardingStore(), preview: Bool = false) {
    isPreview = preview
    var machine = TBDOnboardingMachine(store: store)
    let launch = machine.launch()
    self.machine = machine
    if case .flow = launch { isShowing = true } else { isShowing = false }
    // The form's start values from the saved route, without reading the key from the Keychain.
    if let state = try? registry.load(), let route = state.routes[TBDModelTask.agent.rawValue],
       let connection = state.connections.first(where: { $0.id == route.connectionID }) {
      let local = connection.endpoint.contains("localhost:11434") || connection.endpoint.contains("127.0.0.1:11434")
      agentRuntime = local ? .local : .apiKey
      agentModel = route.model
    }
    if let runtime = machine.record.choices.agentRuntime, runtime != .subscription { agentRuntime = runtime }
    if preview { return }
    linkObserver = NotificationCenter.default.addObserver(forName: .tbdOpenOnboarding, object: nil, queue: .main) { note in
      let raw = note.object as? String ?? ""
      MainActor.assumeIsolated { TBDOnboardingController.shared.open(TBDOnboardingStep(rawValue: raw) ?? .summary) }
    }
  }

  var step: TBDOnboardingStep { machine.record.step }
  var choices: TBDOnboardingChoices { machine.record.choices }
  var editing: Bool { machine.record.editing }
  func isDone(_ step: TBDOnboardingStep) -> Bool { machine.isDone(step, checks) }

  // MARK: Showing, links and checks

  /// A missing-dependency link (or Settings): the flow at that step, in edit mode.
  func open(_ step: TBDOnboardingStep) {
    agentCheckDue = true
    machine.edit(step)
    NSApp.activate(ignoringOtherApps: true)
    MainWindowController.shared.showMainWindow()
    isShowing = true
  }

  func startPolling() {
    guard poll == nil, !isPreview, !Self.isTestHost else { return }
    providers.loadRouting()
    providers.refreshCLIReadiness()
    poll = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshChecks()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  func stopPolling() {
    poll?.cancel()
    poll = nil
    agentKey = ""
  }

  /// The Yes/No shown on the Workspace and Agent steps: the recorded answer, else what is already set up (a legacy
  /// install or a link into a step has no recorded answer; review dev.9 #2).
  var portalAnswer: TBDOnboardingAnswer? { choices.portal ?? (checks.signedIn ? .yes : nil) }
  var agentAnswer: TBDOnboardingAnswer? { choices.agent ?? (checks.agentModelReady ? .yes : nil) }

  /// Edit mode after the first run: back to the app without other changes (review dev.9 #8).
  var canCloseEdit: Bool { editing && machine.record.completed }
  func closeEdit() {
    machine.endEdit()
    stopPolling()
    isShowing = false
  }

  func refreshChecks() async {
    await account.refresh()
    await permissions.refresh()
    speech.refresh()
    var c = TBDOnboardingChecks()
    c.signedIn = account.signedIn
    c.workspaceName = account.workspaces.first { $0.id == account.activeWorkspace }?.name
    // resolve() reads the key from the Keychain: only on the steps that show it, else keep the last answer.
    if agentCheckDue && (step == .agent || step == .summary) {
      agentCheckDue = false
      if (try? TBDAgentModelSetup.resolve(registry)) != nil {
        c.agentModelReady = true
        c.agentModelName = TBDAgentModelSetup.current(registry).model
      }
    } else {
      c.agentModelReady = checks.agentModelReady
      c.agentModelName = checks.agentModelName
    }
    if account.signedIn, step == .agent || step == .summary || checks.agentPaired {
      let state = try? await TBDChatRuntime.shared.accountCall("agentConnection") as? [String: Any]
      c.agentPaired = state?["connected"] as? Bool ?? false
    }
    let granted: [(TBDOnboardingPermission, String)] = [
      (.screenRecording, permissions.screen), (.microphone, permissions.microphone),
      (.accessibility, permissions.accessibility), (.notifications, permissions.notifications),
    ]
    c.granted = Set(granted.filter { $0.1 == "Allowed" }.map(\.0))
    let companion = companionModel()
    c.companionModelReady = companion != nil
    c.companionModelName = companion
    c.companionDownload = downloads.progress[companionLocalModel]
    if step == .models && !c.companionModelReady {
      companionLocalStatus = await TBDAgentModelSetup.localStatus(model: companionLocalModel)
    }
    c.speechModelOnDisk = speech.ready
    c.capturePaused = UserDefaults.standard.bool(forKey: TBDOnboardingStore.legacyDoneKey) && !AppState.shared.isRecording
    c.speechDownload = speech.progress
    if checks != c { checks = c }
  }

  /// The Companion's analysis model in plain words, or nil when none is set up.
  private func companionModel() -> String? {
    // The shared "screen" route wins (LLMProviderRoutingStore); read without its key.
    if let route = (try? registry.load())?.routes["screen"] { return route.model }
    guard providers.canModifyRouting, providers.isProviderConfigured(providers.routing.primary) else { return nil }
    switch providers.routing.primary {
    case .gemini: return "Gemini"
    case .chatGPT: return "your ChatGPT Codex CLI"
    case .claude: return "your Claude Code CLI"
    case .openAICompatible: return OpenAICompatiblePreferences.load()?.modelID ?? "an OpenAI-compatible model"
    case .local: return UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "a model on this Mac"
    }
  }

  #if DEBUG
  /// TBD Dev `--design-shots`: the flow at `step` with fixed choices and checks. Its record lives in a throwaway
  /// suite (cleared first), never in the person's defaults.
  static func preview(step: TBDOnboardingStep, choices: TBDOnboardingChoices, checks: TBDOnboardingChecks,
                      screenRequested: Bool = false, companionLocal: TBDAgentModelSetup.LocalStatus? = nil) -> TBDOnboardingController {
    let suite = TBDIdentity.devBundleID + ".onboarding-shots"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    let store = TBDOnboardingStore(defaults: UserDefaults(suiteName: suite)!)
    store.save(TBDOnboardingRecord(step: step, choices: choices, updatedAt: Date()))
    let flow = TBDOnboardingController(store: store, preview: true)
    flow.checks = checks
    flow.screenRequested = screenRequested
    flow.companionLocalStatus = companionLocal
    if let name = checks.agentModelName { flow.agentModel = name }
    return flow
  }
  #endif

  // MARK: Moving

  /// The StepFlow's index binding: Next, Skip ("No, not now"), Previous and a click on a done step all land here.
  func move(to index: Int) {
    guard TBDOnboardingStep.allCases.indices.contains(index) else { return }
    let target = TBDOnboardingStep.allCases[index]
    defer { if step == .agent || step == .summary { agentCheckDue = true } }
    if target < step {
      while step > target { machine.back() }
    } else if target > step {
      if !isDone(step) { skip(step) }
      machine.forward(checks)
    }
  }

  /// "No, not now": records the No for what is not done yet.
  private func skip(_ step: TBDOnboardingStep) {
    let c = checks
    machine.update { choices in
      switch step {
      case .portal: choices.portal = .no
      case .agent: if !c.agentModelReady { choices.agent = .no }
      case .permissions:
        choices.permissionsNotNow = Set(TBDOnboardingPermission.allCases.filter { !c.granted.contains($0) })
      case .models:
        if !(c.companionModelReady || c.companionDownload != nil) { choices.companion = .no }
        if !(c.speechModelOnDisk || c.speechDownload != nil) { choices.speech = .no }
      case .welcome, .summary: break
      }
    }
  }

  func answer(_ change: (inout TBDOnboardingChoices) -> Void) { machine.update(change) }

  /// "Open TBD". On the first run this also ends the old setup: capture starts when Screen recording is granted
  /// (TBD-DEV7-1 fix 1, `TBDCompanionSetup.finishSetup`).
  func finish() {
    let firstRun = !UserDefaults.standard.bool(forKey: TBDOnboardingStore.legacyDoneKey)
    // The old flag and capture first, then the record: a crash in between never leaves completed=true with
    // didOnboard=false (which would show the retired setup screen; review dev.9 #9).
    if firstRun {
      AppState.shared.enablePersistence()
      TBDCompanionSetup.finishSetup(
        screenRecordingGranted: ScreenRecordingPermissionNotice.isGranted,
        setRecording: { AppState.shared.setRecording($0, persistPreference: $1) },
        postNotice: { ScreenRecordingPermissionNotice.post(reason: "setup_without_screen_recording") })
      UserDefaults.standard.set(true, forKey: TBDOnboardingStore.legacyDoneKey)
    }
    machine.finish()
    stopPolling()
    isShowing = false
  }

  // MARK: Step 1: Portal

  func signIn() { Task { await account.signIn(); await refreshChecks() } }
  func cancelSignIn() { Task { await account.cancel() } }
  func chooseWorkspace(_ id: String) { Task { await account.perform("selectPortalWorkspace", args: [id]); await refreshChecks() } }

  // MARK: Step 2: TBD's agent

  func testAgent() {
    agentTesting = true
    agentTest = nil
    agentTestOK = false
    let runtime = agentRuntime, model = agentModel.trimmingCharacters(in: .whitespacesAndNewlines), key = agentKey
    machine.update { $0.agentRuntime = runtime }
    Task {
      let provider: TBDAgentProvider = runtime == .local ? .ollama : .anthropic
      let result: TBDAgentModelTestResult
      if provider == .ollama {
        let status = await TBDAgentModelSetup.localStatus(model: model)
        agentLocalStatus = status
        result = TBDAgentModelSetup.testResult(status)
      } else if let testKey = TBDAgentModelSetup.testKey(provider: provider, endpoint: TBDAgentModelSetup.anthropicEndpoint, typed: key, registry: registry) {
        result = await TBDAgentModelSetup.test(endpoint: TBDAgentModelSetup.anthropicEndpoint, apiKey: testKey, model: model)
      } else {
        agentTest = "Type your Anthropic API key first."
        agentTesting = false
        return
      }
      if result.isOK {
        do {
          // A key typed under "API key" never goes to the local connection (review dev.9 #7).
          try TBDAgentModelSetup.save(provider: provider, endpoint: provider.fixedEndpoint ?? "", apiKey: provider == .ollama ? "" : key,
                                      model: model, registry: registry)
          agentKey = ""
        } catch { agentTest = error.localizedDescription; agentTesting = false; return }
      }
      agentTestOK = result.isOK
      agentTest = result.isOK ? "Works" : result.message
      agentTesting = false
      agentCheckDue = true
      await refreshChecks()
    }
  }

  /// Pairs TBD's agent card with the workspace (the helper's key connection; the browser approves).
  func pairAgent() {
    pairing = true
    pairError = ""
    Task {
      do {
        let start = try await TBDChatRuntime.shared.accountCall("agentConnect") as? [String: Any] ?? [:]
        pairCode = start["userCode"] as? String ?? ""
        _ = try await TBDChatRuntime.shared.accountCall("awaitAgentConnect")
      } catch {
        pairError = error.localizedDescription
      }
      pairCode = ""
      pairing = false
      await refreshChecks()
    }
  }

  func cancelPairing() { Task { _ = try? await TBDChatRuntime.shared.accountCall("cancelAgentConnect") } }

  // MARK: Step 3: permissions

  func request(_ permission: TBDOnboardingPermission) {
    if permission == .screenRecording { screenRequested = true }
    machine.update { $0.permissionsNotNow.remove(permission) }
    Task { await permissions.request(Self.permissionName(permission)); await refreshChecks() }
  }

  func notNow(_ permission: TBDOnboardingPermission) { machine.update { $0.permissionsNotNow.insert(permission) } }

  static func permissionName(_ p: TBDOnboardingPermission) -> String {
    switch p {
    case .screenRecording: "Screen recording"
    case .microphone: "Microphone"
    case .accessibility: "Accessibility"
    case .notifications: "Notifications"
    }
  }

  /// "Quit and reopen TBD" (spec "Self-relaunch"): macOS gives a new Screen recording grant only at the next start.
  /// A detached shell waits until this process has ended (30 s limit), then opens this same app bundle; never a
  /// second instance (shared database, Chat helper, signer socket). The normal quit path keeps the Listening guard.
  /// macOS runs a quarantined app from Downloads or a disk image from a temporary "App Translocation" copy that is
  /// gone when it quits: reopening that path fails (review dev.9 #1). The person moves TBD to Applications first.
  static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

  func relaunch() {
    guard !relaunching, !Self.isTranslocated else { return }
    relaunching = true
    let pid = ProcessInfo.processInfo.processIdentifier
    machine.markRelaunch(pid: pid)
    var openArgs = ["\"$0\""]
    #if DEBUG
      // The scripted fresh-identity run: the reopened TBD Dev keeps its separate identity.
      if let variant = TBDIdentity.devVariant { openArgs = ["--env", "TBD_DEV_IDENTITY=\(variant)"] + openArgs }
    #endif
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Opens TBD again only when this process really ended within 30 s; a cancelled quit (Listening guard) opens
    // nothing (review dev.9 #4).
    helper.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ \"$i\" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; "
                          + "[ \"$i\" -lt 150 ] && exec /usr/bin/open \(openArgs.joined(separator: " "))",
                        Bundle.main.bundlePath, String(pid)]
    do { try helper.run() } catch { relaunching = false; print("TBD onboarding: relauncher failed: \(error)"); return }
    print("TBD onboarding: quitting to reopen for Screen recording (pid \(pid))")
    AppDelegate.allowTermination = true
    NSApp.terminate(nil)
    // Still running: the quit was cancelled. The person can try again.
    relaunching = false
  }

  // MARK: Downloads into Ollama (dev.10)

  /// TBD's agent model is missing in Ollama: download it, then test and save.
  func downloadAgentModel() {
    let model = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
    downloads.pull(model) { [weak self] in self?.testAgent() }
  }

  /// The Companion's recommended model: download it into Ollama (or use it when it is there) and make it the
  /// Companion's model, as the Settings upgrade sheet does.
  func useCompanionLocalModel() {
    machine.update { $0.companion = .yes; $0.companionRuntime = .local }
    let model = companionLocalModel
    let configure: @MainActor () -> Void = { [weak self] in
      guard let self else { return }
      self.providers.loadRouting()
      self.providers.handleUpgradeSuccess(engine: .ollama, baseURL: LocalEngine.ollama.defaultBaseURL, modelId: model, apiKey: "")
      self.providers.assignPrimaryProvider(.local)
      Task { await self.refreshChecks() }
    }
    if companionLocalStatus == .ready { configure() } else { downloads.pull(model, done: configure) }
  }

  // MARK: Step 4: models

  func setUpCompanion(_ provider: LLMProviderID) {
    machine.update { $0.companion = .yes }
    providers.beginProviderSetup(provider, role: .primary)
  }
}

// MARK: - Root view

struct TBDOnboardingView: View {
  @ObservedObject private var flow: TBDOnboardingController
  @ObservedObject private var account = TBDAccountCoordinator.shared
  @ObservedObject private var permissions = TBDPermissions.shared
  @ObservedObject private var speech = TBDSpeechModelSetup.shared
  @ObservedObject private var providers: ProvidersSettingsViewModel
  @ObservedObject private var downloads = TBDLocalModelDownload.shared

  @MainActor init() { self.init(flow: .shared) }

  @MainActor init(flow: TBDOnboardingController) {
    self.flow = flow
    self.providers = flow.providers
  }

  var body: some View {
    GeometryReader { geo in
      VStack(alignment: .leading, spacing: TBDKit.s5) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: TBDKit.s1) {
            Text("Set up TBD").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
            Text("Everything TBD needs, before you start. A \"No\" is fine: you can change every answer later.")
              .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          }
          Spacer(minLength: TBDKit.s4)
          // Edit mode after the first run (a link or "Review setup"): leave without other changes.
          if flow.canCloseEdit {
            Button("Back to TBD") { flow.closeEdit() }.buttonStyle(TBDButtonStyle(.quiet))
          }
        }
        TBDStepFlow(steps: steps,
                    current: Binding(get: { flow.step.index }, set: { flow.move(to: $0) }),
                    size: CGSize(width: min(860, geo.size.width - 2 * TBDKit.s10), height: max(420, min(640, geo.size.height - 150)))) {
          flow.finish()
        }
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .clipShape(TBDBrickShape())
      }
      .padding(TBDKit.s10)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(TBDColor.paper)
    .onAppear { flow.startPolling() }
    .onDisappear { flow.stopPolling() }
    .sheet(item: Binding(
      get: { providers.setupModalProvider.map(OnbProviderSetup.init) },
      set: { if $0 == nil { providers.cancelProviderSetup() } })
    ) { setup in
      LLMProviderSetupView(
        providerType: setup.id,
        onBack: { providers.cancelProviderSetup() },
        onComplete: { configured in
          let ok = providers.handleProviderSetupCompletion(configured)
          if ok { providers.cancelProviderSetup(); Task { await flow.refreshChecks() } }
          return ok
        })
      .frame(minWidth: 900, minHeight: 650)
    }
  }

  private var nextLabel: String { flow.editing ? "Back to summary" : "Next" }

  private var steps: [TBDStep] {
    [
      TBDStep("Welcome", nextLabel: "Start") { welcome },
      TBDStep("Workspace", nextLabel: nextLabel, optional: true, skipLabel: "No, not now", canAdvance: flow.isDone(.portal)) { portal },
      TBDStep("TBD's agent", nextLabel: nextLabel, optional: true, skipLabel: "No, not now", canAdvance: flow.isDone(.agent)) { agent },
      TBDStep("Permissions", nextLabel: nextLabel, optional: true, skipLabel: "Not now", canAdvance: flow.isDone(.permissions)) { permissionsStep },
      TBDStep("Models", nextLabel: nextLabel, optional: true, skipLabel: "Skip for now", canAdvance: flow.isDone(.models)) { models },
      TBDStep("Summary", nextLabel: "Open TBD") { summary },
    ]
  }

  // MARK: Welcome

  private var welcome: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Welcome to TBD").font(TBDTokens.Typography.display).foregroundStyle(TBDColor.ink)
      Text("TBD sets up four things now, so nothing looks broken later. It takes about 3 minutes.")
        .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
      VStack(alignment: .leading, spacing: TBDKit.s3) {
        bullet("person.2", "Your Teal Brick workspace", "Workspace agents and teams in Chat.")
        bullet("sparkles", "TBD's own agent", "An agent that runs on this Mac.")
        bullet("lock.shield", "macOS permissions", "Screen, microphone, accessibility, notifications.")
        bullet("cpu", "Models", "For your timeline, Daily and Weekly, and dictation.")
      }
      TBDNotice("TBD starts with new, empty data. It does not read or change the data of the old TBD.")
    }
  }

  private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: TBDKit.s3) {
      Image(systemName: symbol).foregroundStyle(TBDColor.tealInk).frame(width: 22).accessibilityHidden(true)
      Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
      Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
    }
  }

  // MARK: Step 1: Portal

  private var portal: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      question("Use TBD with your Teal Brick workspace?")
      HStack(spacing: TBDKit.s3) {
        choice("Yes, sign in", "Workspace agents, teams, Save to Knowledge.", selected: flow.portalAnswer == .yes) { flow.answer { $0.portal = .yes } }
        choice("No", "TBD works on this Mac only. You can sign in later.", selected: flow.portalAnswer == .no) { flow.answer { $0.portal = .no } }
      }
      .fixedSize(horizontal: false, vertical: true)
      if flow.portalAnswer == .yes {
        if account.signedIn {
          panel {
            HStack(spacing: TBDKit.s2) {
              Text("1. Signed in").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
              Spacer(minLength: 0)
              TBDTag(account.email.isEmpty ? "Signed in" : account.email, status: .live)
            }
          }
          panel { workspacePicker }
        } else {
          panel { signInPanel }
          panel {
            HStack(spacing: TBDKit.s2) {
              Text("2. Choose a workspace").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
              Spacer(minLength: 0)
              Text("after you approve the code").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
          }
        }
      }
    }
  }

  private var signInPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(spacing: TBDKit.s2) {
        Text("1. Approve a code in your browser").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        Spacer(minLength: 0)
        if !account.code.isEmpty { TBDTag("Waiting for you", status: .busy) }
      }
      if account.code.isEmpty {
        Button(account.busy ? "Starting…" : "Sign in") { flow.signIn() }
          .buttonStyle(TBDButtonStyle(.primary)).disabled(account.busy)
        Text("TBD opens your browser. You approve the code there.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else {
        HStack(spacing: TBDKit.s4) {
          Text(account.code).font(TBDFonts.nunito(TBDKit.textH2, TBDKit.weightHead)).foregroundStyle(TBDColor.ink).textSelection(.enabled)
          Button("Copy code") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(account.code, forType: .string)
          }.buttonStyle(TBDButtonStyle(.quiet))
          Button("Cancel") { flow.cancelSignIn() }.buttonStyle(TBDButtonStyle(.quiet))
        }
        Text("Your browser is open. Approve this code there; TBD goes on by itself.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      if !account.error.isEmpty {
        Text(account.error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
      }
    }
  }

  private var workspacePicker: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Text("2. Choose a workspace").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
      if account.workspaces.isEmpty {
        Text(account.busy ? "Loading your workspaces…" : "No workspace found for this account. Create one in the Portal, then come back.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      ForEach(account.workspaces) { ws in
        choice(ws.name, ws.id == account.activeWorkspace ? "Chosen" : "", selected: ws.id == account.activeWorkspace) {
          flow.chooseWorkspace(ws.id)
        }
      }
    }
  }

  // MARK: Step 2: TBD's agent

  private var agent: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      question("Run TBD's own agent on this Mac?")
      HStack(spacing: TBDKit.s3) {
        choice("Yes", "An agent in Chat that can use your timeline and notes.", selected: flow.agentAnswer == .yes) { flow.answer { $0.agent = .yes } }
        choice("No", "Chat shows only your workspace agents.", selected: flow.agentAnswer == .no) { flow.answer { $0.agent = .no } }
      }
      .fixedSize(horizontal: false, vertical: true)
      if flow.agentAnswer == .yes {
        fieldRow("Agent") {
          TBDTag("TBD's agent", status: .live)
          Text("Codex, Eve and LangChain: coming later").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        // C287: an Agent SDK app may not offer a subscription login, so TBD's agent shows only these two.
        fieldRow("Runs on") {
          segment("API key", selected: flow.agentRuntime == .apiKey) {
            flow.agentRuntime = .apiKey
            if flow.agentModel == TBDAgentModelSetup.defaultLocalModel { flow.agentModel = TBDAgentModelSetup.defaultModel }
          }
          segment("Model on this Mac", selected: flow.agentRuntime == .local) {
            flow.agentRuntime = .local
            if flow.agentModel == TBDAgentModelSetup.defaultModel { flow.agentModel = TBDAgentModelSetup.defaultLocalModel }
          }
        }
        panel { agentModelPanel }
        if account.signedIn { panel { pairingPanel } }
      }
    }
  }

  private var agentModelPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      if flow.agentRuntime == .local {
        Text("Ollama on this Mac. TBD does not download this model. In Terminal, run: ollama pull \(flow.agentModel.trimmingCharacters(in: .whitespaces))")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else {
        HStack(spacing: TBDKit.s3) {
          Text("Anthropic API key").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 140, alignment: .leading)
          SecureField(flow.checks.agentModelReady ? "Saved. Type a new key to replace it." : "sk-ant-…", text: $flow.agentKey)
            .textFieldStyle(.roundedBorder)
        }
      }
      HStack(spacing: TBDKit.s3) {
        Text("Model").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 140, alignment: .leading)
        TextField("Model", text: $flow.agentModel).textFieldStyle(.roundedBorder).font(TBDTokens.Typography.mono)
      }
      HStack(spacing: TBDKit.s3) {
        Button(flow.agentTesting ? "Testing…" : "Test and save") { flow.testAgent() }
          .buttonStyle(TBDButtonStyle(.secondary)).disabled(flow.agentTesting)
        if flow.agentTestOK || (flow.agentTest == nil && flow.checks.agentModelReady) {
          TBDTag(flow.agentTestOK ? "Works · saved" : "Set up: \(flow.checks.agentModelName ?? "")", status: .live)
        } else if let message = flow.agentTest {
          Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
        }
      }
      // dev.10: the model is missing in Ollama: download it here (it continues in the background).
      let agentModelName = flow.agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if flow.agentRuntime == .local, let p = downloads.progress[agentModelName] {
        progress(p)
        Text("Downloading \(agentModelName): \(Int((p * 100).rounded()))% · you can go on, it continues in the background")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else if flow.agentRuntime == .local, case .modelMissing = flow.agentLocalStatus {
        Button("Download \(agentModelName)") { flow.downloadAgentModel() }.buttonStyle(TBDButtonStyle(.primary))
      }
      if flow.agentRuntime == .local, let error = downloads.errors[agentModelName] {
        Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var pairingPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(spacing: TBDKit.s3) {
        Text("Workspace").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 140, alignment: .leading)
        if flow.checks.agentPaired {
          TBDTag("Paired with \(flow.checks.workspaceName ?? "your workspace")", status: .live)
          Text("Your workspace agents can see TBD's agent.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        } else if flow.pairing {
          if !flow.pairCode.isEmpty {
            Text(flow.pairCode).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).textSelection(.enabled)
            TBDTag("Approve it in your browser", status: .busy)
          }
          Button("Cancel") { flow.cancelPairing() }.buttonStyle(TBDButtonStyle(.quiet))
        } else {
          Button("Pair with \(flow.checks.workspaceName ?? "the workspace")") { flow.pairAgent() }
            .buttonStyle(TBDButtonStyle(.secondary)).disabled(!flow.checks.agentModelReady)
          if !flow.checks.agentModelReady {
            Text("Set up the model first.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          }
        }
      }
      if !flow.pairError.isEmpty {
        Text(flow.pairError).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
      }
    }
  }

  // MARK: Step 3: permissions

  private var permissionsStep: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      question("Allow what TBD needs on this Mac")
      VStack(spacing: 0) {
        permissionRow(.screenRecording, "display", "For your timeline, Daily and Weekly.", "TBD records nothing. Timeline, Daily and Weekly stay empty.")
        divider
        permissionRow(.microphone, "mic", "For dictation and meeting notes.", "Dictation and meeting notes do not work.")
        divider
        permissionRow(.accessibility, "accessibility", "To type dictation into other apps.", "Dictation cannot type into other apps.")
        divider
        permissionRow(.notifications, "bell", "When Daily is ready, or an agent needs you.", "TBD cannot tell you when an agent needs you.")
      }
      .background(TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
      Text("TBD checks every 2 seconds. Calendar access is asked later, in Meetings.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      if !permissions.error.isEmpty { Text(permissions.error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink) }
    }
  }

  private func permissionRow(_ p: TBDOnboardingPermission, _ symbol: String, _ detail: String, _ without: String) -> some View {
    let granted = flow.checks.granted.contains(p)
    let notNow = flow.choices.permissionsNotNow.contains(p)
    return HStack(spacing: TBDKit.s3) {
      Image(systemName: symbol).foregroundStyle(TBDColor.inkSoft).frame(width: 22).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(TBDOnboardingController.permissionName(p)).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        Text(granted || !notNow ? detail : "Not now. \(without)").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      Spacer(minLength: TBDKit.s4)
      if granted {
        TBDTag("Allowed", status: .live)
      } else if p == .screenRecording && flow.screenRequested && TBDOnboardingController.isTranslocated {
        Text("Move TBD to Applications, quit it and open it again. macOS turns on screen recording then.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 320, alignment: .trailing)
      } else if p == .screenRecording && flow.screenRequested {
        VStack(alignment: .trailing, spacing: TBDKit.s1) {
          HStack(spacing: TBDKit.s2) {
            Button("Open System Settings") { ScreenRecordingPermissionNotice.openSystemSettings() }.buttonStyle(TBDButtonStyle(.quiet))
            Button("Quit and reopen TBD") { flow.relaunch() }.buttonStyle(TBDButtonStyle(.primary))
          }
          Text("After you allow TBD there, macOS turns it on when TBD starts again. You come back here.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
      } else {
        HStack(spacing: TBDKit.s2) {
          if !notNow { Button("Not now") { flow.notNow(p) }.buttonStyle(TBDButtonStyle(.quiet)) }
          Button("Allow") { flow.request(p) }.buttonStyle(TBDButtonStyle(.secondary))
        }
      }
    }
    .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s3)
  }

  private var divider: some View { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }

  // MARK: Step 4: models

  private var models: some View {
    VStack(alignment: .leading, spacing: TBDKit.s4) {
      question("Analyse your screen activity with a model?")
      if flow.checks.companionModelReady {
        panel {
          HStack(spacing: TBDKit.s3) {
            Text("Daily and Weekly use \(flow.checks.companionModelName ?? "your model").").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            Spacer(minLength: 0)
            TBDTag("Set up", status: .live)
          }
        }
      }
      fieldRow("Subscription") {
        if TBDSubscriptionPolicy.isAllowed(.claudeCodeCLI) {
          segment("Use your Claude Code CLI", selected: false) { flow.setUpCompanion(.claude) }
        }
        if TBDSubscriptionPolicy.isAllowed(.codexCLI) {
          segment("Use your ChatGPT Codex CLI", selected: false) { flow.setUpCompanion(.chatGPT) }
        }
      }
      fieldRow("API key") {
        segment("Gemini", selected: false) { flow.setUpCompanion(.gemini) }
        segment("OpenAI-compatible", selected: false) { flow.setUpCompanion(.openAICompatible) }
      }
      if !flow.checks.companionModelReady { panel { companionLocalPanel } }
      fieldRow("On this Mac") {
        segment("Other local model (LM Studio, Ollama)", selected: false) { flow.setUpCompanion(.local) }
      }
      Text("You sign in to a CLI yourself, in that CLI. TBD never sees or stores its login.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      question("Speech model for dictation and meetings")
      panel {
        VStack(alignment: .leading, spacing: TBDKit.s3) {
          HStack(spacing: TBDKit.s3) {
            Text(speech.title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
            Text("works offline · \(speech.size)").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            Spacer(minLength: 0)
            if speech.ready {
              TBDTag("On this Mac", status: .live)
            } else if speech.progress != nil {
              TBDTag("Downloading", status: .busy)
            } else {
              if flow.choices.speech != .no { Button("Not now") { flow.answer { $0.speech = .no } }.buttonStyle(TBDButtonStyle(.quiet)) }
              Button("Download") { flow.answer { $0.speech = .yes }; speech.download() }.buttonStyle(TBDButtonStyle(.secondary))
            }
          }
          if let p = speech.progress {
            progress(p)
            Text("\(Int((p * 100).rounded()))% · you can go on, it continues in the background").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          }
          if let error = speech.error { Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink) }
        }
      }
    }
  }

  /// dev.10: the recommended local model for the Companion, downloaded into Ollama from here.
  private var companionLocalPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(spacing: TBDKit.s3) {
        Text("Qwen3-VL 4B on this Mac").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        Text("free · works offline · about 3.3 GB · uses Ollama").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        Spacer(minLength: 0)
        if let _ = downloads.progress[flow.companionLocalModel] {
          TBDTag("Downloading", status: .busy)
        } else if flow.companionLocalStatus == .notRunning {
          Button("Check again") { Task { await flow.refreshChecks() } }.buttonStyle(TBDButtonStyle(.quiet))
        } else if flow.companionLocalStatus != nil {
          Button(flow.companionLocalStatus == .ready ? "Use it" : "Download") { flow.useCompanionLocalModel() }
            .buttonStyle(TBDButtonStyle(.secondary))
        }
      }
      if let p = downloads.progress[flow.companionLocalModel] {
        progress(p)
        Text("\(Int((p * 100).rounded()))% · you can go on, it continues in the background")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else if flow.companionLocalStatus == .notRunning {
        Text("Ollama is not running on this Mac. Install it from ollama.com and open it, then push \"Check again\".")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      }
      if let error = downloads.errors[flow.companionLocalModel] {
        Text(error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func progress(_ value: Double) -> some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(TBDColor.line)
        Capsule().fill(TBDColor.teal).frame(width: g.size.width * min(max(value, 0), 1))
      }
    }
    .frame(height: 8)
    .accessibilityLabel("Download progress")
    .accessibilityValue("\(Int((value * 100).rounded())) percent")
  }

  // MARK: Step 5: summary

  private var summary: some View {
    let lines = TBDOnboardingSummary.lines(flow.checks)
    let off = lines.filter { !$0.on }.count
    return VStack(alignment: .leading, spacing: TBDKit.s4) {
      VStack(alignment: .leading, spacing: TBDKit.s1) {
        Text(TBDOnboardingSummary.headline(lines)).font(TBDTokens.Typography.display).foregroundStyle(TBDColor.ink)
        if off > 0 {
          Text("You can turn them on later in Settings, or now with the buttons below.")
            .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
        }
      }
      VStack(spacing: 0) {
        ForEach(lines.indices, id: \.self) { i in
          if i > 0 { divider }
          summaryLine(lines[i])
        }
      }
      .background(TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
    }
  }

  /// A missing area is never red: a "No" is a valid answer.
  private func summaryLine(_ line: TBDOnboardingLine) -> some View {
    HStack(spacing: TBDKit.s3) {
      Image(systemName: line.on ? "checkmark.circle" : "circle.dashed")
        .foregroundStyle(line.on ? TBDColor.tealInk : TBDColor.muted).frame(width: 22).accessibilityHidden(true)
      Text(line.area).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).frame(width: 190, alignment: .leading)
      Text(line.text).font(TBDTokens.Typography.hint).foregroundStyle(line.on ? TBDColor.inkSoft : TBDColor.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: TBDKit.s3)
      Button(line.action) {
        switch line.fix {
        case .step(let step): flow.open(step)
        case .portal: if let url = URL(string: "https://portal.tealbrick.com") { NSWorkspace.shared.open(url) }
        }
      }
      .buttonStyle(TBDButtonStyle(line.on ? .quiet : .secondary))
      // VoiceOver says the action and the area ("Sign in, Workspace"); the line's text stays its own element
      // (a combined element hid the action word, dev.9 follow-up 1).
      .accessibilityLabel("\(line.action), \(line.area)")
    }
    .padding(.horizontal, TBDKit.s4).padding(.vertical, TBDKit.s2)
    .accessibilityElement(children: .contain)
  }

  // MARK: Shared pieces

  private func question(_ text: String) -> some View {
    Text(text).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink).accessibilityAddTraits(.isHeader)
  }

  private func choice(_ title: String, _ detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: TBDKit.s3) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? TBDColor.tealInk : TBDColor.muted).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
          if !detail.isEmpty {
            Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(TBDKit.s3)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(selected ? TBDColor.tealWash : TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(selected ? TBDColor.tealWashLine : TBDColor.line, lineWidth: TBDKit.hair))
      .contentShape(TBDBrickShape())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(title, action: action).buttonStyle(TBDButtonStyle(selected ? .primary : .quiet))
  }

  private func fieldRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: TBDKit.s3) {
      Text(label).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 110, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
  }

  private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(TBDKit.s4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(TBDColor.paper, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}

/// `sheet(item:)` needs an Identifiable value.
private struct OnbProviderSetup: Identifiable {
  let id: LLMProviderID
}
