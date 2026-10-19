import Foundation
import SwiftUI
import TBDDesign

@MainActor
final class ProvidersSettingsViewModel: ObservableObject {
  @Published private(set) var routing = LLMProviderRouting(primary: .gemini)
  @Published private(set) var hasLoadedRouting = false
  @Published var setupModalProvider: LLMProviderID? {
    didSet {
      if setupModalProvider == nil {
        pendingSetupRole = nil
      }
    }
  }
  @Published var providerRoutingErrorMessage: String?

  @Published var selectedGeminiModel: GeminiModel
  @Published var localEngine: LocalEngine {
    didSet {
      guard oldValue != localEngine else { return }
      UserDefaults.standard.set(localEngine.rawValue, forKey: "llmLocalEngine")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localBaseURL: String {
    didSet {
      guard oldValue != localBaseURL else { return }
      UserDefaults.standard.set(localBaseURL, forKey: "llmLocalBaseURL")
    }
  }
  @Published var localModelId: String {
    didSet {
      guard oldValue != localModelId else { return }
      UserDefaults.standard.set(localModelId, forKey: "llmLocalModelId")
      LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
      refreshUpgradeBannerState()
    }
  }
  @Published var localAPIKey: String {
    didSet {
      guard oldValue != localAPIKey else { return }
      persistLocalAPIKey(localAPIKey)
    }
  }
  @Published var localTestBaseURL = ""
  @Published var localTestModelID = ""
  @Published var localTestAPIKey = ""
  @Published var showLocalModelUpgradeBanner = false
  @Published var isShowingLocalModelUpgradeSheet = false
  @Published var upgradeStatusMessage: String?
  @Published private(set) var openAICompatiblePreset: OpenAICompatiblePreset = .openRouter
  @Published private(set) var openAICompatibleBaseURL =
    OpenAICompatibleConfiguration.openRouterBaseURL
  @Published private(set) var openAICompatibleModelID = ""
  @Published private(set) var openAICompatibleAPIKey = ""
  @Published private(set) var codexCLIInstalled = false
  @Published private(set) var claudeCLIInstalled = false
  @Published private(set) var isCheckingCLIReadiness = false

  @Published var geminiPromptOverridesLoaded = false
  @Published var isUpdatingGeminiPromptState = false
  @Published var useCustomGeminiTitlePrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var useCustomGeminiSummaryPrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var useCustomGeminiDetailedPrompt = false {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiTitlePromptText = GeminiPromptDefaults.titleBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiSummaryPromptText = GeminiPromptDefaults.summaryBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }
  @Published var geminiDetailedPromptText = GeminiPromptDefaults.detailedSummaryBlock {
    didSet { persistGeminiPromptOverridesIfReady() }
  }

  @Published var ollamaPromptOverridesLoaded = false
  @Published var isUpdatingOllamaPromptState = false
  @Published var useCustomOllamaTitlePrompt = false {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var useCustomOllamaSummaryPrompt = false {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var ollamaTitlePromptText = OllamaPromptDefaults.titleBlock {
    didSet { persistOllamaPromptOverridesIfReady() }
  }
  @Published var ollamaSummaryPromptText = OllamaPromptDefaults.summaryBlock {
    didSet { persistOllamaPromptOverridesIfReady() }
  }

  @Published var agentPromptOverridesLoaded = false
  @Published var isUpdatingAgentPromptState = false
  @Published var useCustomAgentTitlePrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var useCustomAgentSummaryPrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var useCustomAgentDetailedPrompt = false {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentTitlePromptText = CodexPromptDefaults.titleBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentSummaryPromptText = CodexPromptDefaults.summaryBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var agentDetailedPromptText = CodexPromptDefaults.detailedSummaryBlock {
    didSet { persistAgentPromptOverridesIfReady() }
  }
  @Published var selectedAgentPromptProvider: LLMProviderID = .chatGPT {
    didSet {
      guard oldValue != selectedAgentPromptProvider else { return }
      guard selectedAgentPromptProvider == .chatGPT || selectedAgentPromptProvider == .claude else {
        selectedAgentPromptProvider = oldValue
        return
      }
      loadAgentPromptOverridesIfNeeded(force: true)
    }
  }

  private var savedGeminiModel: GeminiModel
  private var pendingSetupRole: ProviderRoutingRole?

  init() {
    let preference = GeminiModelPreference.load()
    selectedGeminiModel = preference.primary
    savedGeminiModel = preference.primary

    let rawEngine = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
    let engine = LocalEngine(rawValue: rawEngine) ?? .ollama
    localEngine = engine
    localBaseURL =
      UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? LocalEngine.ollama.defaultBaseURL

    let defaults = UserDefaults.standard
    let storedModel = defaults.string(forKey: "llmLocalModelId") ?? ""
    if storedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      localModelId = LocalModelPreferences.defaultModelId(for: engine)
    } else {
      localModelId = storedModel
    }

    localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? ""
    localTestBaseURL = localBaseURL
    localTestModelID = localModelId
    localTestAPIKey = localAPIKey

    if let configuration = OpenAICompatiblePreferences.load() {
      openAICompatiblePreset = configuration.preset
      openAICompatibleBaseURL = configuration.baseURL
      openAICompatibleModelID = configuration.modelID
    }
    openAICompatibleAPIKey =
      KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  func handleOnAppear() {
    loadRouting()
    reloadLocalProviderSettings()
    reloadOpenAICompatibleSettings()
    refreshCLIReadiness()
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    refreshUpgradeBannerState()
    loadGeminiPromptOverridesIfNeeded()
    loadOllamaPromptOverridesIfNeeded()
    if currentProvider == .chatGPT || currentProvider == .claude {
      selectedAgentPromptProvider = currentProvider
    } else {
      loadAgentPromptOverridesIfNeeded()
    }
  }

  func handleLocalTestCompletion(success: Bool) {
    guard success else { return }

    localBaseURL = localTestBaseURL
    localModelId = localTestModelID
    localAPIKey = localTestAPIKey
    UserDefaults.standard.set(localTestBaseURL, forKey: "llmLocalBaseURL")
    UserDefaults.standard.set(localTestModelID, forKey: "llmLocalModelId")
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
    persistLocalAPIKey(localTestAPIKey)
    refreshUpgradeBannerState()
  }

  func markUpgradeBannerKeepLegacy() {
    LocalModelPreferences.markUpgradeDismissed(true)
    showLocalModelUpgradeBanner = false
  }

  func markUpgradeBannerUpgrade() {
    LocalModelPreferences.markUpgradeDismissed(false)
  }

  func applyProviderChangeSideEffects(for provider: LLMProviderID) {
    reloadLocalProviderSettings()
    reloadOpenAICompatibleSettings()
    if provider == .gemini {
      loadGeminiPromptOverridesIfNeeded(force: true)
    } else if provider == .local {
      loadOllamaPromptOverridesIfNeeded(force: true)
    } else if provider == .chatGPT || provider == .claude {
      selectedAgentPromptProvider = provider
      loadAgentPromptOverridesIfNeeded(force: true)
    }
    refreshUpgradeBannerState()
  }

  func reloadLocalProviderSettings() {
    localBaseURL = UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? localBaseURL
    localModelId = UserDefaults.standard.string(forKey: "llmLocalModelId") ?? localModelId
    localAPIKey = UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? localAPIKey
    let raw = UserDefaults.standard.string(forKey: "llmLocalEngine") ?? localEngine.rawValue
    localEngine = LocalEngine(rawValue: raw) ?? localEngine
    localTestBaseURL = localBaseURL
    localTestModelID = localModelId
    localTestAPIKey = localAPIKey
    LocalModelPreferences.syncPreset(for: localEngine, modelId: localModelId)
  }

  func reloadOpenAICompatibleSettings() {
    let configuration = OpenAICompatiblePreferences.load() ?? .openRouter()
    openAICompatiblePreset = configuration.preset
    openAICompatibleBaseURL = configuration.baseURL
    openAICompatibleModelID = configuration.modelID
    openAICompatibleAPIKey =
      KeychainManager.shared.retrieve(for: OpenAICompatiblePreferences.keychainProvider) ?? ""
  }

  func refreshCLIReadiness() {
    guard !isCheckingCLIReadiness else { return }
    isCheckingCLIReadiness = true

    Task.detached { [weak self] in
      let codexInstalled = CLIDetector.isInstalled(.codex)
      let claudeInstalled = CLIDetector.isInstalled(.claude)
      await MainActor.run { [weak self] in
        self?.codexCLIInstalled = codexInstalled
        self?.claudeCLIInstalled = claudeInstalled
        self?.isCheckingCLIReadiness = false
      }
    }
  }

  var usingRecommendedLocalModel: Bool {
    let comparisonEngine = localEngine == .custom ? .ollama : localEngine
    let normalized = localModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    let recommended = LocalModelPreset.recommended.modelId(for: comparisonEngine)
    if normalized.caseInsensitiveCompare(recommended) == .orderedSame {
      return true
    }
    return LocalModelPreferences.currentPreset() == .qwen3VL4B
  }

  func refreshUpgradeBannerState() {
    let shouldShow = LocalModelPreferences.shouldShowUpgradeBanner(
      engine: localEngine, modelId: localModelId)
    showLocalModelUpgradeBanner = shouldShow && currentProvider == .local
  }

  func handleUpgradeSuccess(engine: LocalEngine, baseURL: String, modelId: String, apiKey: String) {
    let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    localEngine = engine
    localBaseURL = baseURL
    localModelId = modelId
    localAPIKey = normalizedKey
    localTestBaseURL = baseURL
    localTestModelID = modelId
    localTestAPIKey = normalizedKey
    UserDefaults.standard.set(baseURL, forKey: "llmLocalBaseURL")
    UserDefaults.standard.set(modelId, forKey: "llmLocalModelId")
    UserDefaults.standard.set(engine.rawValue, forKey: "llmLocalEngine")
    persistLocalAPIKey(normalizedKey)
    LocalModelPreferences.syncPreset(for: engine, modelId: modelId)
    LocalModelPreferences.markUpgradeDismissed(true)
    refreshUpgradeBannerState()
    upgradeStatusMessage = String(
      localized: "Upgraded to \(LocalModelPreset.recommended.displayName)")

    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
      self?.upgradeStatusMessage = nil
    }
  }

  func persistLocalAPIKey(_ value: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      UserDefaults.standard.removeObject(forKey: "llmLocalAPIKey")
    } else {
      UserDefaults.standard.set(trimmed, forKey: "llmLocalAPIKey")
    }
  }

  var currentProvider: LLMProviderID { routing.primary }

  var primaryRoutingProviderId: LLMProviderID { routing.primary }

  var secondaryRoutingProviderId: LLMProviderID? { routing.secondary }

  var hasCodexOrClaudeProviderInRouting: Bool {
    routing.primary == .chatGPT || routing.primary == .claude
      || routing.secondary == .chatGPT || routing.secondary == .claude
  }

  func loadRouting() {
    do {
      let storedRouting = try LLMProviderRoutingStore.load()
      routing = storedRouting
      hasLoadedRouting = true
      providerRoutingErrorMessage = nil
      applyProviderChangeSideEffects(for: storedRouting.primary)
    } catch {
      hasLoadedRouting = false
      providerRoutingErrorMessage =
        String(
          localized:
            "TBD couldn't load your provider routing. Your saved providers were left unchanged."
        )
    }
  }

  var routingProviders: [CompactProviderInfo] {
    providerCatalog
  }

  var canModifyRouting: Bool {
    hasLoadedRouting
  }

  func beginProviderSetup(_ providerId: LLMProviderID, role: ProviderRoutingRole) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    pendingSetupRole = role
    setupModalProvider = providerId
  }

  func editProviderConfiguration(_ providerId: LLMProviderID) {
    guard providerCatalog.contains(where: { $0.id == providerId }) else { return }
    pendingSetupRole = .setupOnly
    setupModalProvider = providerId
  }

  @discardableResult
  func handleProviderSetupCompletion(_ providerId: LLMProviderID) -> Bool {
    switch providerId {
    case .local:
      reloadLocalProviderSettings()
    case .openAICompatible:
      reloadOpenAICompatibleSettings()
    case .chatGPT:
      codexCLIInstalled = true
      refreshCLIReadiness()
    case .claude:
      claudeCLIInstalled = true
      refreshCLIReadiness()
    case .gemini:
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    }
    let role = pendingSetupRole ?? .setupOnly
    let routingSucceeded: Bool
    switch role {
    case .primary:
      routingSucceeded = assignPrimaryProvider(providerId, requiresReadinessCheck: false)
    case .secondary:
      routingSucceeded = assignSecondaryProvider(providerId, requiresReadinessCheck: false)
    case .setupOnly:
      routingSucceeded = true
    }
    guard routingSucceeded else { return false }

    recordProviderSetupCompleted(providerId)
    pendingSetupRole = nil
    return true
  }

  func cancelProviderSetup() {
    pendingSetupRole = nil
    setupModalProvider = nil
  }

  func setPrimaryOrSetup(_ providerId: LLMProviderID) {
    guard canModifyRouting else { return }
    if isProviderConfigured(providerId) {
      assignPrimaryProvider(providerId)
    } else {
      beginProviderSetup(providerId, role: .primary)
    }
  }

  func setSecondaryOrSetup(_ providerId: LLMProviderID) {
    guard canModifyRouting else { return }
    if isProviderConfigured(providerId) {
      assignSecondaryProvider(providerId)
    } else {
      beginProviderSetup(providerId, role: .secondary)
    }
  }

  @discardableResult
  func assignPrimaryProvider(
    _ providerId: LLMProviderID,
    requiresReadinessCheck: Bool = true
  ) -> Bool {
    guard canModifyRouting else { return false }
    guard providerId != routing.primary else { return true }
    if requiresReadinessCheck {
      guard isProviderConfigured(providerId) else { return false }
    }

    let previousPrimary = routing.primary
    let shouldSwapWithSecondary = routing.secondary == providerId
    let updatedRouting = LLMProviderRouting(
      primary: providerId,
      secondary: shouldSwapWithSecondary ? previousPrimary : routing.secondary
    )
    guard saveRouting(updatedRouting) else { return false }

    if providerId == .gemini {
      let preference = GeminiModelPreference.load()
      selectedGeminiModel = preference.primary
      savedGeminiModel = preference.primary
    }

    if shouldSwapWithSecondary {
    }
    return true
  }

  @discardableResult
  func assignSecondaryProvider(
    _ providerId: LLMProviderID,
    requiresReadinessCheck: Bool = true
  ) -> Bool {
    guard canModifyRouting else { return false }
    if requiresReadinessCheck {
      guard isProviderConfigured(providerId) else { return false }
    }

    if providerId == routing.secondary { return true }

    if providerId == routing.primary {
      guard let existingSecondary = routing.secondary else { return false }
      let previousPrimary = routing.primary
      let updatedRouting = LLMProviderRouting(
        primary: existingSecondary,
        secondary: previousPrimary
      )
      guard saveRouting(updatedRouting) else { return false }

      return true
    }

    let updatedRouting = LLMProviderRouting(primary: routing.primary, secondary: providerId)
    guard saveRouting(updatedRouting) else { return false }
    return true
  }

  func canAssignPrimary(_ providerId: LLMProviderID) -> Bool {
    canModifyRouting && providerId != routing.primary && isProviderConfigured(providerId)
  }

  func canAssignSecondary(_ providerId: LLMProviderID) -> Bool {
    guard canModifyRouting else { return false }
    guard isProviderConfigured(providerId) else { return false }
    if providerId == routing.primary {
      return routing.secondary != nil
    }
    return true
  }

  func isProviderConfigured(_ providerId: LLMProviderID) -> Bool {
    switch providerId {
    case .gemini:
      let key = KeychainManager.shared.retrieve(for: "gemini") ?? ""
      return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .chatGPT:
      return codexCLIInstalled && LLMProviderSetupPreferences.isComplete(.chatGPT)
    case .claude:
      return claudeCLIInstalled && LLMProviderSetupPreferences.isComplete(.claude)
    case .openAICompatible:
      guard let configuration = OpenAICompatiblePreferences.load(), configuration.isComplete else {
        return false
      }
      if configuration.preset == .custom {
        return true
      }
      let key =
        KeychainManager.shared.retrieve(
          for: OpenAICompatiblePreferences.keychainProvider) ?? ""
      return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .local:
      let baseURL = (UserDefaults.standard.string(forKey: "llmLocalBaseURL") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let modelId = (UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return !baseURL.isEmpty && !modelId.isEmpty
    }
  }

  func isProviderReadinessChecking(_ providerId: LLMProviderID) -> Bool {
    isCheckingCLIReadiness && (providerId == .chatGPT || providerId == .claude)
  }

  func clearBackupProvider() {
    guard canModifyRouting else { return }
    guard routing.secondary != nil else { return }
    let updatedRouting = LLMProviderRouting(primary: routing.primary)
    guard saveRouting(updatedRouting) else { return }
  }

  func isBackupProvider(_ providerId: LLMProviderID) -> Bool {
    routing.secondary == providerId
  }

  var backupProviderDisplayName: String {
    guard let backupProvider = routing.secondary else { return String(localized: "Not configured") }
    return providerDisplayName(backupProvider)
  }

  @discardableResult
  private func saveRouting(_ updatedRouting: LLMProviderRouting) -> Bool {
    guard canModifyRouting else { return false }
    do {
      try LLMProviderRoutingStore.save(updatedRouting)
      withAnimation(TBDMotion.spring) {
        routing = updatedRouting
      }
      providerRoutingErrorMessage = nil
      applyProviderChangeSideEffects(for: updatedRouting.primary)
      return true
    } catch {
      providerRoutingErrorMessage =
        String(
          localized:
            "TBD couldn't save your provider routing. Your previous selection is still active.")
      return false
    }
  }

  private func recordProviderSetupCompleted(_ providerId: LLMProviderID) {
    var properties: [String: Any] = [
      "provider": providerId.analyticsName,
      "provider_id": providerId.rawValue,
    ]
    if providerId == .local {
      properties["local_engine"] =
        UserDefaults.standard.string(forKey: "llmLocalEngine") ?? "ollama"
      properties["model_id"] =
        UserDefaults.standard.string(forKey: "llmLocalModelId") ?? "unknown"
      let localAPIKey = (UserDefaults.standard.string(forKey: "llmLocalAPIKey") ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      properties["has_api_key"] = !localAPIKey.isEmpty
    } else if providerId == .chatGPT {
      properties["chat_cli_tool"] = "codex"
    } else if providerId == .claude {
      properties["chat_cli_tool"] = "claude"
    } else if providerId == .openAICompatible {
      properties["endpoint_kind"] = openAICompatiblePreset.rawValue
      properties["has_api_key"] =
        !openAICompatibleAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  func persistGeminiModelSelection(_ model: GeminiModel, source: String) {
    guard model != savedGeminiModel else { return }
    savedGeminiModel = model
    GeminiModelPreference(primary: model).save()

    Task { @MainActor in
    }
  }

  private var providerCatalog: [CompactProviderInfo] {
    [
      CompactProviderInfo(
        id: .claude,
        summary: String(localized: "Uses Claude Code through your existing Claude plan")
      ),
      CompactProviderInfo(
        id: .chatGPT,
        summary: String(localized: "Uses Codex CLI through your existing ChatGPT plan")
      ),
      CompactProviderInfo(
        id: .gemini,
        summary: String(localized: "Gemini free tier • fast & accurate")
      ),
      CompactProviderInfo(
        id: .openAICompatible,
        summary: String(localized: "OpenRouter or another OpenAI Chat Completions endpoint")
      ),
      CompactProviderInfo(
        id: .local,
        summary: String(localized: "Private & offline • 16GB+ RAM • less intelligent")
      ),
    ]
  }

  func statusText(for providerId: LLMProviderID) -> String? {
    guard currentProvider == providerId else { return nil }

    switch providerId {
    case .local:
      let engineName: String
      switch localEngine {
      case .ollama: engineName = "Ollama"
      case .lmstudio: engineName = "LM Studio"
      case .custom: engineName = String(localized: "Custom")
      }
      let displayModel = localModelId.isEmpty ? String(localized: "qwen2.5vl:3b") : localModelId
      let truncatedModel =
        displayModel.count > 30 ? String(displayModel.prefix(27)) + "..." : displayModel
      return String(localized: "\(engineName) - \(truncatedModel)")
    case .gemini:
      return selectedGeminiModel.displayName
    case .chatGPT:
      return cliStatusLabel(for: .chatGPT)
    case .claude:
      return cliStatusLabel(for: .claude)
    case .openAICompatible:
      return openAICompatibleModelID.isEmpty
        ? String(localized: "OpenAI-compatible endpoint") : openAICompatibleModelID
    }
  }

  func cliStatusLabel(for providerId: LLMProviderID) -> String {
    if isProviderReadinessChecking(providerId) {
      return String(localized: "Checking installation…")
    }
    switch providerId {
    case .chatGPT:
      return codexCLIInstalled
        ? String(localized: "Codex CLI detected") : String(localized: "Codex CLI not detected")
    case .claude:
      return claudeCLIInstalled
        ? String(localized: "Claude Code detected") : String(localized: "Claude Code not detected")
    default:
      return String(localized: "Not applicable")
    }
  }

  var connectionHealthLabel: String {
    switch currentProvider {
    case .gemini:
      return String(localized: "Gemini API")
    case .local:
      return String(localized: "Local API")
    case .chatGPT:
      return String(localized: "Codex CLI")
    case .claude:
      return String(localized: "Claude Code")
    case .openAICompatible:
      return String(localized: "OpenAI-compatible API")
    }
  }

  func providerDisplayName(_ id: LLMProviderID) -> String {
    switch id {
    case .local: return String(localized: "Local")
    case .gemini: return "Gemini"
    case .chatGPT: return "ChatGPT"
    case .claude: return "Claude"
    case .openAICompatible: return "OpenAI-compatible"
    }
  }

  // Prompt override load/persist/reset lives in
  // ProvidersSettingsViewModel+PromptOverrides.swift.
}

struct CompactProviderInfo: Identifiable {
  let id: LLMProviderID
  let summary: String

  var providerTableName: String {
    switch id {
    case .local: return String(localized: "Local")
    case .gemini: return "Gemini"
    case .chatGPT: return "ChatGPT"
    case .claude: return "Claude"
    case .openAICompatible: return "OpenAI-compatible"
    }
  }
}

enum ProviderRoutingRole {
  case primary
  case secondary
  case setupOnly
}
