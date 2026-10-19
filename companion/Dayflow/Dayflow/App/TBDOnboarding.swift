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
  @Published var agentModel = TBDAgentModelSetup.defaultLocalModel {
    // A status checked for another model name must not offer "Download" for this one (review dev.10 #4).
    didSet { if agentModel != oldValue { agentLocalStatus = nil } }
  }
  @Published var agentKey = ""
  @Published private(set) var agentTest: String?
  @Published private(set) var agentTestOK = false
  @Published private(set) var agentTesting = false
  @Published private(set) var pairCode = ""
  @Published private(set) var pairing = false
  @Published private(set) var pairError = ""
  /// Step 2, harness (WP-HARNESS L3): TBD's agent (Claude Agent SDK) or the bundled LangChain agent. The panel shows
  /// the choice; the setting changes only when the 4 checks pass (`useLangChain`).
  let harnessStore = TBDAgentHarnessStore()
  @Published private(set) var harnessKind: TBDAgentHarnessKind = .claudeAgentSDK
  @Published var harnessShown: TBDAgentHarnessKind = .claudeAgentSDK
  @Published var langchainProvider: TBDLangChainProvider = .anthropic
  @Published var openAIModel = ""
  @Published var openAIKey = ""
  /// Whether an OpenAI key is in the Keychain (read when the panel shows and after a save; not on every render).
  @Published private(set) var openAIKeyStored = false
  func refreshOpenAIKey() { openAIKeyStored = harnessStore.hasOpenAIKey }
  @Published private(set) var harnessBusy = false
  @Published private(set) var harnessMessage: String?
  /// The 4 checks of the last LangChain try: nil = not run, true/false = result.
  @Published private(set) var langchainChecks: [(name: String, ok: Bool?, detail: String)] = TBDOnboardingController.emptyChecks
  static let emptyChecks: [(name: String, ok: Bool?, detail: String)] = [
    ("Installed", nil, ""), ("Model", nil, ""), ("Answers", nil, ""), ("TBD's tools", nil, ""),
  ]

  /// Step 2, cloud (WP-HARNESS step 1, C287 (1)): the person's own Bedrock / Vertex AI / Foundry setting.
  let cloudStore = TBDAgentCloudStore()
  @Published var cloud = TBDAgentCloud(provider: .bedrock, model: TBDAgentCloudProvider.bedrock.exampleModel, region: "us-east-1") {
    didSet { if cloud != oldValue && !loadingCloud { cloudEdited = true } }
  }
  @Published var cloudKey = "" { didSet { if !cloudKey.isEmpty { cloudEdited = true } } }
  /// The person changed a cloud field (or chose a provider/typed a key) since it was last saved or loaded. Only then
  /// does Next save (review dev.11 #1: looking at the defaults must never replace a working route).
  @Published private(set) var cloudEdited = false
  private var loadingCloud = false
  @Published private(set) var cloudMessage: String?
  /// Whether a key for the shown provider is in the Keychain (read when the panel shows, after Save and Remove).
  @Published private(set) var cloudKeyStored = false
  /// The Companion's local model could not be made its model (review dev.10 #5).
  @Published private(set) var companionMessage: String?
  /// The shown cloud fields are the active, saved setting (the "Saved" tag shows only then; review dev.10 #6).
  var cloudSaved: Bool { cloudStore.isActive && cloudStore.load() == cloud }
  /// Typed, complete cloud fields that are not saved yet: Next saves them (review dev.10 #6b).
  var cloudReadyToSave: Bool {
    agentRuntime == .cloud && agentAnswer == .yes && cloudEdited && !cloudSaved
      && cloud.missing(hasKey: !cloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cloudKeyStored) == nil
  }
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
    if let saved = cloudStore.load() { loadingCloud = true; cloud = saved; loadingCloud = false }
    harnessKind = harnessStore.kind
    harnessShown = harnessKind
    langchainProvider = harnessStore.provider
    openAIModel = harnessStore.openAIModel
    if cloudStore.isActive { agentRuntime = .cloud }
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
    cloudKey = ""
  }

  /// The Yes/No shown on the Workspace and Agent steps: the recorded answer, else what is already set up (a legacy
  /// install or a link into a step has no recorded answer; review dev.9 #2).
  var portalAnswer: TBDOnboardingAnswer? { choices.portal ?? (checks.signedIn ? .yes : nil) }
  var agentAnswer: TBDOnboardingAnswer? { choices.agent ?? (checks.agentModelReady ? .yes : nil) }

  /// The person's own Portal (the active Portal profile's issuer: portal.tealbrick.com, dev.tealbrick.com or a
  /// self-hosted Portal; review dev.12 #4). The public Portal only when no profile is loaded yet.
  var portalURL: URL {
    let issuer = account.profiles.first { $0.id == account.activeProfile }?.issuer ?? ""
    if let url = URL(string: issuer), ["https", "http"].contains(url.scheme ?? "") { return url }
    return URL(string: "https://portal.tealbrick.com")!
  }

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
      // The route TBD's agent really starts with: the registry route or the person's cloud setting.
      if let route = try? TBDAgentModelSetup.resolveRoute(registry, cloud: cloudStore) {
        c.agentModelReady = true
        c.agentModelName = route.model
        c.agentCloud = cloudStore.isActive ? route.source : nil
      }
    } else {
      c.agentModelReady = checks.agentModelReady
      c.agentModelName = checks.agentModelName
      c.agentCloud = checks.agentCloud
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
    // C282 (WP1b): the paid apps behind TBD's functions, from the helper's cached snapshot (10 min; last good on error).
    if account.signedIn, step == .summary {
      c.paidApps = TBDEntitlements(helperValue: try? await TBDChatRuntime.shared.accountCall("entitlements")).summaryChecks
    } else if account.signedIn {
      c.paidApps = checks.paidApps
    }
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
                      screenRequested: Bool = false, companionLocal: TBDAgentModelSetup.LocalStatus? = nil,
                      langchain: Bool = false) -> TBDOnboardingController {
    let suite = TBDIdentity.devBundleID + ".onboarding-shots"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    let store = TBDOnboardingStore(defaults: UserDefaults(suiteName: suite)!)
    store.save(TBDOnboardingRecord(step: step, choices: choices, updatedAt: Date()))
    let flow = TBDOnboardingController(store: store, preview: true)
    flow.checks = checks
    flow.screenRequested = screenRequested
    flow.companionLocalStatus = companionLocal
    if langchain {
      flow.harnessShown = .langchain
      flow.harnessKind = .langchain
      flow.langchainChecks = [("Installed", true, ""), ("Model", true, "gpt-oss:20b · Ollama on this Mac"),
                              ("Answers", true, "One reply in this check"), ("TBD's tools", true, "timeline, transcripts, workspace apps")]
    }
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
      if step == .agent && cloudReadyToSave {
        // A failed save stays on the step with its message (review dev.11 #2).
        guard saveCloudNow() else { return }
        // The saved route resolves; count it at once so Forward does not wait for the next check.
        var c = checks
        c.agentModelReady = true
        c.agentModelName = cloud.model.trimmingCharacters(in: .whitespacesAndNewlines)
        c.agentCloud = cloud.provider.title
        checks = c
        agentCheckDue = true
      }
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
          // The tested route is now TBD's agent's route; a cloud setting stays saved for later.
          cloudStore.deactivate()
          restartAgent()
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

  // MARK: Harness (WP-HARNESS L3)

  /// Back to TBD's agent (Claude Agent SDK); the agent restarts with it.
  func useTBDAgent() {
    harnessStore.kind = .claudeAgentSDK
    harnessKind = .claudeAgentSDK
    harnessShown = .claudeAgentSDK
    harnessMessage = nil
    agentCheckDue = true
    restartAgent()
    Task { await refreshChecks() }
  }

  /// The 4 checks of a PENDING LangChain choice (review dev.13 #2): the setting changes only when all pass. The helper
  /// runs the self-test on a temporary agent with the LangChain route; the person's running agent is not touched.
  func useLangChain() {
    guard !harnessBusy, !Self.isTestHost, !isPreview else { return }
    harnessBusy = true
    harnessMessage = nil
    var checks = Self.emptyChecks
    func finish(_ message: String?) {
      langchainChecks = checks
      harnessMessage = message
      harnessBusy = false
      agentCheckDue = true
      Task { await refreshChecks() }
    }
    func fail(_ message: String) { finish("\(message) \(harnessKind == .langchain ? "The LangChain agent stays on." : "TBD's agent stays on.")") }
    // 1. Installed: the bundled LangChain agent is in this app.
    let bundle = Bundle.main.resourceURL?.appendingPathComponent("Chat/agent-langchain.mjs")
    checks[0] = ("Installed", bundle.map { FileManager.default.fileExists(atPath: $0.path) } ?? false, "")
    guard checks[0].ok == true else { fail("The LangChain agent is not in this build of TBD."); return }
    // 2. Model: the LangChain agent's own settings (they do not change TBD's agent) resolve for it.
    harnessStore.provider = langchainProvider
    if langchainProvider == .openai {
      harnessStore.openAIModel = openAIModel
      do { try harnessStore.saveOpenAIKey(openAIKey); openAIKey = ""; refreshOpenAIKey() } catch { fail(error.localizedDescription); return }
    }
    do {
      let route = try TBDAgentModelSetup.resolveRoute(registry, cloud: cloudStore, harness: harnessStore, as: .langchain)
      checks[1] = ("Model", true, "\(route.model) · \(route.source)")
    } catch {
      checks[1] = ("Model", false, error.localizedDescription)
      fail(error.localizedDescription); return
    }
    // 3 + 4. One round trip and a read-only probe of each of TBD's tool families, on a temporary LangChain agent.
    Task {
      let answer = (try? await TBDChatRuntime.shared.accountCall("agentSelfTest", args: [TBDAgentHarnessKind.langchain.rawValue])) as? [String: Any] ?? [:]
      let ok = answer["ok"] as? Bool ?? false
      checks[2] = ("Answers", ok, ok ? "One reply in this check" : (answer["error"] as? String ?? "No answer from the LangChain agent."))
      let tools = answer["tools"] as? [String: Any] ?? [:]
      let configured = (tools["configured"] as? [String] ?? []).filter { $0 != "ask_person" }
      let loaded = Set(tools["loaded"] as? [String] ?? [])
      let probes = tools["probes"] as? [String: Any] ?? [:]
      let failed = configured.filter { !loaded.contains($0) || (probes[$0].map { !($0 is NSNull) } ?? true) }
      let label = { (f: String) in ["companion": "timeline", "listening": "transcripts", "tealbrick": "workspace apps"][f] ?? f }
      let toolsOK = ok && !configured.isEmpty && failed.isEmpty
      checks[3] = ("TBD's tools", toolsOK, toolsOK ? configured.map(label).joined(separator: ", ")
        : failed.isEmpty ? "No TBD tool answered." : "Not answering: \(failed.map(label).joined(separator: ", "))")
      guard checks[2].ok == true else { fail("The LangChain agent did not answer: \(checks[2].detail)"); return }
      guard toolsOK else { fail("The LangChain agent could not reach TBD's tools."); return }
      // All 4 passed: only now TBD's agent becomes the LangChain agent.
      harnessStore.kind = .langchain
      harnessKind = .langchain
      machine.update { $0.agent = .yes }
      restartAgent()
      finish(nil)
    }
  }

  /// Removes the stored OpenAI key (review dev.13 #15). The LangChain agent on OpenAI then needs a new key.
  func removeOpenAIKey() {
    do { try harnessStore.removeOpenAIKey(); harnessMessage = nil } catch { harnessMessage = error.localizedDescription }
    refreshOpenAIKey()
    agentCheckDue = true
    Task { await refreshChecks() }
  }

  // MARK: Cloud provider (WP-HARNESS step 1)

  /// Saves the cloud setting and makes it TBD's agent's route. There is no cheap test call for every provider (Bedrock
  /// signs requests with AWS); the first chat message checks it and shows the provider's own error.
  func saveCloud() { _ = saveCloudNow() }

  /// Saves the shown cloud setting; true when it was saved.
  @discardableResult
  func saveCloudNow() -> Bool {
    let typed = cloudKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasKey = !typed.isEmpty || (cloud.secretName != nil && cloudStore.hasKey(cloud.provider))
    if let missing = cloud.missing(hasKey: hasKey) { cloudMessage = missing; return false }
    do {
      try cloudStore.save(cloud, key: typed)
      cloudKey = ""
      cloudEdited = false
      // Cloud providers work with TBD's agent (Claude Agent SDK) only: saving one switches back to it.
      if harnessStore.kind == .langchain { harnessStore.kind = .claudeAgentSDK; harnessKind = .claudeAgentSDK; harnessShown = .claudeAgentSDK }
      cloudMessage = nil
      refreshCloudKey()
      machine.update { $0.agent = .yes; $0.agentRuntime = .cloud }
      agentCheckDue = true
      restartAgent()
      Task { await refreshChecks() }
      return true
    } catch {
      cloudMessage = error.localizedDescription
      return false
    }
  }

  func refreshCloudKey() { cloudKeyStored = cloud.secretName != nil && cloudStore.hasKey(cloud.provider) }

  /// Removes the stored key for the shown provider (Bedrock then uses the AWS profile again).
  func removeCloudKey() {
    do { try cloudStore.removeKey(cloud.provider); cloudMessage = nil } catch { cloudMessage = error.localizedDescription }
    refreshCloudKey()
    if cloudStore.isActive { agentCheckDue = true; restartAgent(); Task { await refreshChecks() } }
  }

  /// TBD's agent starts again with the saved route (it reuses a running process otherwise; review dev.10 #6).
  private func restartAgent() {
    guard !Self.isTestHost, !isPreview else { return }
    Task { _ = try? await TBDChatRuntime.shared.accountCall("restartAgent", args: ["tbd-default"]) }
  }

  func chooseCloud(_ provider: TBDAgentCloudProvider) {
    guard provider != cloud.provider else { return }
    cloudEdited = true
    cloud = cloudStore.load().flatMap { $0.provider == provider ? $0 : nil }
      ?? TBDAgentCloud(provider: provider, model: provider.exampleModel, region: provider == .vertex ? "us-east5" : provider == .bedrock ? "us-east-1" : "")
    cloudKey = ""
    cloudMessage = nil
    refreshCloudKey()
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
    companionMessage = nil
    let model = companionLocalModel
    let configure: @MainActor () -> Void = { [weak self] in
      guard let self else { return }
      self.providers.loadRouting()
      self.providers.handleUpgradeSuccess(engine: .ollama, baseURL: LocalEngine.ollama.defaultBaseURL, modelId: model, apiKey: "")
      // It replaces the Companion's current model, as choosing it in Settings does; "yes" only when it worked.
      if self.providers.assignPrimaryProvider(.local) {
        self.machine.update { $0.companion = .yes; $0.companionRuntime = .local }
      } else {
        self.companionMessage = "TBD could not make Qwen3-VL 4B the model for Daily and Weekly. Choose it in Settings › Models › Advanced."
      }
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
      let cardWidth = min(860, geo.size.width - 2 * TBDKit.s10)
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
        // The header is as wide as the card, so the column stays centred in the window.
        .frame(width: cardWidth)
        TBDStepFlow(steps: steps,
                    current: Binding(get: { flow.step.index }, set: { flow.move(to: $0) }),
                    size: CGSize(width: cardWidth, height: max(420, min(900, geo.size.height - 150)))) {
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
      // While typed cloud fields wait to be saved, the only way forward is "Save and continue"; "No" is the tile above
      // (the kit's StepFlow sends Next and Skip through the same path, review dev.11 #1).
      TBDStep("TBD's agent", nextLabel: flow.cloudReadyToSave ? "Save and continue" : nextLabel, optional: !flow.cloudReadyToSave, skipLabel: "No, not now",
              canAdvance: flow.isDone(.agent) || flow.cloudReadyToSave) { agent },
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
          segment("TBD's agent", selected: flow.harnessShown == .claudeAgentSDK) {
            if flow.harnessKind == .claudeAgentSDK { flow.harnessShown = .claudeAgentSDK } else { flow.useTBDAgent() }
          }
          segment("LangChain agent", selected: flow.harnessShown == .langchain) { flow.harnessShown = .langchain }
          Text("Codex and Eve: coming later").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        if flow.harnessShown == .langchain { panel { langchainPanel } }
        // C287: an Agent SDK app may not offer a subscription login, so TBD's agent shows only these two.
        if flow.harnessShown == .claudeAgentSDK { fieldRow("Runs on") {
          segment("API key", selected: flow.agentRuntime == .apiKey) {
            flow.agentRuntime = .apiKey
            if flow.agentModel == TBDAgentModelSetup.defaultLocalModel { flow.agentModel = TBDAgentModelSetup.defaultModel }
          }
          segment("Model on this Mac", selected: flow.agentRuntime == .local) {
            flow.agentRuntime = .local
            if flow.agentModel == TBDAgentModelSetup.defaultModel { flow.agentModel = TBDAgentModelSetup.defaultLocalModel }
          }
          segment("Cloud (Bedrock, Vertex, Foundry)", selected: flow.agentRuntime == .cloud) { flow.agentRuntime = .cloud }
        }
        if flow.agentRuntime == .cloud { panel { cloudPanel } } else { panel { agentModelPanel } } }
        if account.signedIn { panel { pairingPanel } }
      }
    }
  }

  private var agentModelPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      if flow.agentRuntime == .local {
        Text("Uses Ollama on this Mac. \"Test and save\" checks that the model is there; if it is missing, TBD can download it.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      } else {
        HStack(spacing: TBDKit.s3) {
          Text("Anthropic API key").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 140, alignment: .leading)
          SecureField(flow.checks.agentModelReady && flow.checks.agentCloud == nil ? "Saved. Type a new key to replace it." : "sk-ant-…", text: $flow.agentKey)
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
        if flow.agentTestOK || (flow.agentTest == nil && flow.checks.agentModelReady && flow.checks.agentCloud == nil) {
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

  /// WP-HARNESS L3: the LangChain agent — its model (your Anthropic key or a model on this Mac: the setting below
  /// "TBD's agent" uses; or your OpenAI key) and the 4 checks that must pass before it is used.
  private var langchainPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      Text("A LangChain agent bundled with TBD. It uses TBD's tools (timeline, transcripts, workspace apps) and can ask you questions. No shell or file tools in this version.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: TBDKit.s2) {
        segment("Anthropic key or model on this Mac", selected: flow.langchainProvider == .anthropic) { flow.langchainProvider = .anthropic }
        segment("OpenAI key", selected: flow.langchainProvider == .openai) { flow.langchainProvider = .openai }
      }
      if flow.langchainProvider == .openai {
        cloudField("OpenAI model ID", $flow.openAIModel, mono: true)
        HStack(spacing: TBDKit.s3) {
          Text("OpenAI API key").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 170, alignment: .leading)
          SecureField(flow.openAIKeyStored ? "A key is saved. Type a new key to replace it." : "sk-…", text: $flow.openAIKey).textFieldStyle(.roundedBorder)
          if flow.openAIKeyStored { Button("Remove key") { flow.removeOpenAIKey() }.buttonStyle(TBDButtonStyle(.quiet)) }
        }
        .onAppear { flow.refreshOpenAIKey() }
      } else {
        Text("Uses the model you set up for TBD's agent: \(flow.checks.agentCloud == nil ? (flow.checks.agentModelName ?? "none yet") : "a cloud provider, which LangChain cannot use").")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      }
      HStack(alignment: .top, spacing: TBDKit.s4) {
        ForEach(flow.langchainChecks.indices, id: \.self) { i in
          let check = flow.langchainChecks[i]
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: TBDKit.s1) {
              Image(systemName: check.ok == true ? "checkmark.circle" : check.ok == false ? "xmark.circle" : "circle.dashed")
                .foregroundStyle(check.ok == true ? TBDColor.tealInk : TBDColor.muted).accessibilityHidden(true)
              Text("\(i + 1). \(check.name)").font(TBDTokens.Typography.label).foregroundStyle(TBDColor.ink)
            }
            if !check.detail.isEmpty {
              Text(check.detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
            }
          }
          .accessibilityElement(children: .combine)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      HStack(spacing: TBDKit.s3) {
        if flow.harnessKind == .langchain {
          TBDTag("In use: LangChain agent", status: .live)
          Button(flow.harnessBusy ? "Checking…" : "Check again") { flow.useLangChain() }.buttonStyle(TBDButtonStyle(.quiet)).disabled(flow.harnessBusy)
        } else {
          Button(flow.harnessBusy ? "Checking…" : "Check and use LangChain agent") { flow.useLangChain() }
            .buttonStyle(TBDButtonStyle(.primary)).disabled(flow.harnessBusy)
        }
        if let message = flow.harnessMessage {
          Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// WP-HARNESS step 1: TBD's agent on the person's own cloud provider (C287 (1)).
  private var cloudPanel: some View {
    VStack(alignment: .leading, spacing: TBDKit.s3) {
      HStack(spacing: TBDKit.s2) {
        ForEach(TBDAgentCloudProvider.allCases, id: \.self) { provider in
          segment(provider.title, selected: flow.cloud.provider == provider) { flow.chooseCloud(provider) }
        }
      }
      Text(cloudHint).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
      cloudField("Model ID", $flow.cloud.model, mono: true)
      switch flow.cloud.provider {
      case .bedrock:
        cloudField("AWS region", $flow.cloud.region)
        cloudField("AWS profile (optional)", $flow.cloud.awsProfile)
        cloudSecret("Bedrock API key (optional)")
      case .vertex:
        cloudField("Project ID", $flow.cloud.project)
        cloudField("Region", $flow.cloud.region)
      case .foundry:
        cloudField("Resource name", $flow.cloud.resource)
        cloudSecret("Foundry API key")
      }
      HStack(spacing: TBDKit.s3) {
        Button("Save") { flow.saveCloud() }.buttonStyle(TBDButtonStyle(.secondary))
        if let message = flow.cloudMessage {
          Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
        } else if flow.cloudSaved && flow.checks.agentModelReady {
          TBDTag("Saved: \(flow.cloud.provider.title)", status: .live)
          Text("Not tested yet: your first chat message checks the connection.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
      }
    }
  }

  private var cloudHint: String {
    switch flow.cloud.provider {
    case .bedrock: "Uses your AWS sign-in on this Mac (aws configure or AWS SSO), or a Bedrock API key if you type one."
    case .vertex: "Uses your Google sign-in on this Mac. In Terminal, run: gcloud auth application-default login"
    case .foundry: "Your Microsoft Foundry resource and its API key."
    }
  }

  private func cloudField(_ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
    HStack(spacing: TBDKit.s3) {
      Text(label).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 170, alignment: .leading)
      TextField(label, text: text).textFieldStyle(.roundedBorder).font(mono ? TBDTokens.Typography.mono : TBDTokens.Typography.body)
    }
  }

  private func cloudSecret(_ label: String) -> some View {
    HStack(spacing: TBDKit.s3) {
      Text(label).font(TBDTokens.Typography.label).foregroundStyle(TBDColor.muted).frame(width: 170, alignment: .leading)
      SecureField(flow.cloudKeyStored ? "A key is saved. Type a new key to replace it." : "", text: $flow.cloudKey).textFieldStyle(.roundedBorder)
      if flow.cloudKeyStored {
        Button("Remove key") { flow.removeCloudKey() }.buttonStyle(TBDButtonStyle(.quiet))
      }
    }
    .onAppear { flow.refreshCloudKey() }
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
      if let message = flow.companionMessage {
        Text(message).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink).fixedSize(horizontal: false, vertical: true)
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
      Image(systemName: line.on ? "checkmark.circle" : line.neutral ? "questionmark.circle" : "circle.dashed")
        .foregroundStyle(line.on ? TBDColor.tealInk : TBDColor.muted).frame(width: 22).accessibilityHidden(true)
      Text(line.area).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink).frame(width: 190, alignment: .leading)
      Text(line.text).font(TBDTokens.Typography.hint).foregroundStyle(line.on || line.neutral ? TBDColor.inkSoft : TBDColor.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: TBDKit.s3)
      Button(line.action) {
        switch line.fix {
        case .step(let step): flow.open(step)
        case .portal: NSWorkspace.shared.open(flow.portalURL)
        }
      }
      .buttonStyle(TBDButtonStyle(line.on || line.neutral ? .quiet : .secondary))
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
