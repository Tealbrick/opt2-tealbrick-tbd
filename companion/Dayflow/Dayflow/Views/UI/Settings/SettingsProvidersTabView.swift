import AppKit
import SwiftUI
import TBDDesign

struct SettingsProvidersTabView: View {
  @ObservedObject var viewModel: ProvidersSettingsViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      if viewModel.currentProvider == .local, viewModel.showLocalModelUpgradeBanner {
        LocalModelUpgradeBanner(
          preset: .qwen3VL4B,
          onKeepLegacy: { viewModel.markUpgradeBannerKeepLegacy() },
          onUpgrade: {
            viewModel.markUpgradeBannerUpgrade()
            viewModel.isShowingLocalModelUpgradeSheet = true
          }
        )
        .transition(.opacity)
      }

      if let status = viewModel.upgradeStatusMessage {
        TBDNotice(status, tone: .live)
      }

      if let error = viewModel.providerRoutingErrorMessage {
        TBDNotice(error, tone: .needsYou)
      }

      currentConfigurationSection
      connectionHealthSection
      failoverRoutingSection

      if viewModel.currentProvider == .gemini {
        geminiModelSection
      }

      primaryPromptCustomizationSection
      if viewModel.hasCodexOrClaudeProviderInRouting {
        agentPromptCustomizationSection
      }
    }
  }

  // MARK: - Current configuration

  private var currentConfigurationSection: some View {
    SettingsSection(
      title: String(localized: "Current configuration"),
      subtitle: String(localized: "Active provider and runtime details."),
      isFirst: true
    ) {
      VStack(alignment: .leading, spacing: 0) {
        summaryRows

        HStack(spacing: 8) {
          SettingsSecondaryButton(
            title: String(localized: "Edit configuration"),
            action: { viewModel.editProviderConfiguration(viewModel.primaryRoutingProviderId) }
          )

          if viewModel.currentProvider == .local {
            SettingsSecondaryButton(
              title: viewModel.usingRecommendedLocalModel
                ? String(localized: "Manage local model")
                : String(localized: "Upgrade local model"),
              action: { viewModel.isShowingLocalModelUpgradeSheet = true }
            )
          }
        }
        .padding(.top, 18)
      }
    }
  }

  @ViewBuilder
  private var summaryRows: some View {
    SettingsRow(label: String(localized: "Primary provider")) {
      HStack(spacing: 8) {
        SettingsMetadata(
          text: viewModel.providerDisplayName(viewModel.primaryRoutingProviderId))
        SettingsBadge(text: String(localized: "PRIMARY"), isAccent: true)
      }
    }

    if let backupProvider = viewModel.secondaryRoutingProviderId {
      SettingsRow(label: String(localized: "Secondary provider")) {
        HStack(spacing: 8) {
          SettingsMetadata(text: viewModel.providerDisplayName(backupProvider))
          SettingsBadge(text: String(localized: "SECONDARY"))
        }
      }
    } else {
      SettingsRow(label: String(localized: "Secondary provider")) {
        SettingsMetadata(text: String(localized: "Not configured"))
      }
    }

    switch viewModel.currentProvider {
    case .local:
      SettingsRow(label: String(localized: "Engine")) {
        SettingsMetadata(text: viewModel.localEngine.displayName)
      }
      SettingsRow(label: String(localized: "Model")) {
        SettingsMetadata(
          text: viewModel.localModelId.isEmpty
            ? String(localized: "Not configured") : viewModel.localModelId)
      }
      SettingsRow(label: String(localized: "Endpoint")) {
        SettingsMetadata(text: viewModel.localBaseURL)
      }
      let hasKey = !viewModel.localAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      SettingsRow(label: String(localized: "API key"), showsDivider: false) {
        SettingsMetadata(
          text: hasKey ? String(localized: "Stored in UserDefaults") : String(localized: "Not set"))
      }
    case .gemini:
      SettingsRow(label: String(localized: "Model preference")) {
        SettingsMetadata(text: viewModel.selectedGeminiModel.displayName)
      }
      SettingsRow(label: String(localized: "API key"), showsDivider: false) {
        SettingsMetadata(
          text: KeychainManager.shared.retrieve(for: "gemini") != nil
            ? String(localized: "Stored safely in Keychain") : String(localized: "Not set"))
      }
    case .chatGPT, .claude:
      SettingsRow(label: String(localized: "CLI")) {
        SettingsMetadata(text: viewModel.cliStatusLabel(for: viewModel.currentProvider))
      }
    case .openAICompatible:
      SettingsRow(label: String(localized: "Preset")) {
        SettingsMetadata(
          text: viewModel.openAICompatiblePreset == .openRouter
            ? "OpenRouter" : String(localized: "Custom"))
      }
      SettingsRow(label: String(localized: "Model")) {
        SettingsMetadata(
          text: viewModel.openAICompatibleModelID.isEmpty
            ? String(localized: "Not configured") : viewModel.openAICompatibleModelID)
      }
      SettingsRow(label: String(localized: "Endpoint")) {
        SettingsMetadata(text: viewModel.openAICompatibleBaseURL)
      }
      let hasKey = !viewModel.openAICompatibleAPIKey.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
      SettingsRow(label: String(localized: "API key"), showsDivider: false) {
        SettingsMetadata(
          text: hasKey
            ? String(localized: "Stored safely in Keychain") : String(localized: "Not set"))
      }
    }
  }

  // MARK: - Connection health

  private var connectionHealthSection: some View {
    SettingsSection(
      title: String(localized: "Connection health"),
      subtitle: String(localized: "Run a quick test for the primary provider.")
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Text(viewModel.connectionHealthLabel)
          .font(TBDTokens.Typography.control)
          .foregroundStyle(TBDColor.ink)

        switch viewModel.currentProvider {
        case .gemini:
          TestConnectionView(
            model: viewModel.selectedGeminiModel,
            onTestComplete: { _ in }
          )
        case .local:
          LocalLLMTestView(
            baseURL: $viewModel.localTestBaseURL,
            modelId: $viewModel.localTestModelID,
            apiKey: $viewModel.localTestAPIKey,
            engine: viewModel.localEngine,
            showInputs: viewModel.localEngine == .custom,
            onTestComplete: { success in
              viewModel.handleLocalTestCompletion(success: success)
            }
          )
        case .chatGPT:
          ChatCLITestView(
            selectedTool: .codex,
            onTestComplete: { _ in }
          )
        case .claude:
          ChatCLITestView(
            selectedTool: .claude,
            onTestComplete: { _ in }
          )
        case .openAICompatible:
          VStack(alignment: .leading, spacing: 10) {
            Text(
              "The setup test sends a small image to verify multimodal support and may incur a provider charge."
            )
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
            .fixedSize(horizontal: false, vertical: true)
            SettingsSecondaryButton(title: String(localized: "Test connection")) {
              viewModel.editProviderConfiguration(.openAICompatible)
            }
          }
        }
      }
    }
  }

  // MARK: - Failover routing

  private var failoverRoutingSection: some View {
    SettingsSection(
      title: String(localized: "Failover routing"),
      subtitle: String(localized: "Choose primary and secondary providers.")
    ) {
      VStack(alignment: .leading, spacing: TBDKit.s3) {
        let providers = viewModel.routingProviders
        ForEach(providers, id: \.id) { provider in
          routingRow(provider: provider)
        }
      }
    }
  }

  /// A provider is an object, so it is a card.
  private func routingRow(
    provider: CompactProviderInfo
  ) -> some View {
    let isConfigured = viewModel.isProviderConfigured(provider.id)
    let isChecking = viewModel.isProviderReadinessChecking(provider.id)
    let isPrimary = viewModel.primaryRoutingProviderId == provider.id
    let isSecondary = viewModel.isBackupProvider(provider.id)
    let canSetSecondary =
      viewModel.canModifyRouting
      && (viewModel.canAssignSecondary(provider.id) || (!isConfigured && !isPrimary))

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 10) {
        Text(provider.providerTableName)
          .font(TBDTokens.Typography.title)
          .foregroundStyle(TBDColor.ink)

        Spacer()

        if isPrimary {
          SettingsBadge(text: String(localized: "PRIMARY"), isAccent: true)
        }
        if isSecondary {
          SettingsBadge(text: String(localized: "SECONDARY"))
        }
        if isChecking && !isPrimary && !isSecondary {
          SettingsBadge(text: String(localized: "CHECKING"))
        } else if !isChecking && !isConfigured && (isPrimary || isSecondary) {
          SettingsBadge(text: String(localized: "NEEDS ATTENTION"))
        } else if !isChecking && !isPrimary && !isSecondary && isConfigured {
          SettingsBadge(
            text: provider.id == .chatGPT || provider.id == .claude
              ? "DETECTED" : "CONFIGURED")
        } else if !isChecking && !isPrimary && !isSecondary {
          SettingsBadge(text: String(localized: "NOT SET"))
        }
      }

      Text(provider.summary)
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        if !isConfigured {
          SettingsSecondaryButton(title: String(localized: "Setup")) {
            viewModel.beginProviderSetup(provider.id, role: .setupOnly)
          }
        }

        SettingsSecondaryButton(title: String(localized: "Edit configuration")) {
          viewModel.editProviderConfiguration(provider.id)
        }

        if !isPrimary {
          SettingsSecondaryButton(
            title: String(localized: "Set primary"),
            isDisabled: !viewModel.canModifyRouting
          ) {
            viewModel.setPrimaryOrSetup(provider.id)
          }
        }

        if !isSecondary {
          SettingsSecondaryButton(
            title: String(localized: "Set secondary"), isDisabled: !canSetSecondary
          ) {
            viewModel.setSecondaryOrSetup(provider.id)
          }
        } else {
          SettingsSecondaryButton(title: String(localized: "Unset secondary")) {
            viewModel.clearBackupProvider()
          }
        }

      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tbdCard()
  }

  // MARK: - Gemini model preference

  private var geminiModelSection: some View {
    SettingsSection(
      title: String(localized: "Gemini model preference"),
      subtitle: String(localized: "Choose which Gemini model TBD should prioritize.")
    ) {
      VStack(alignment: .leading, spacing: 14) {
        TBDSegmented(
          selection: $viewModel.selectedGeminiModel,
          options: GeminiModel.allCases.map { ($0, $0.displayName) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Gemini model"))
        .onChange(of: viewModel.selectedGeminiModel) { _, newValue in
          viewModel.persistGeminiModelSelection(newValue, source: "settings")
        }

        Text(GeminiModelPreference(primary: viewModel.selectedGeminiModel).fallbackSummary)
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)

        Text(
          "TBD automatically downgrades if your chosen model is rate limited or unavailable."
        )
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
      }
    }
  }

  // MARK: - Prompt customization

  @ViewBuilder
  private var primaryPromptCustomizationSection: some View {
    switch viewModel.currentProvider {
    case .gemini:
      promptSection(
        title: String(localized: "Gemini prompt customization"),
        subtitle: String(localized: "Override TBD's defaults to tailor card generation."),
        intro:
          String(
            localized:
              "Overrides apply only when their toggle is on. Unchecked sections fall back to TBD's defaults."
          ),
        sections: [
          promptEditorConfig(
            heading: String(localized: "Card titles"),
            description: String(
              localized: "Shape how card titles read and tweak the example list."),
            isEnabled: $viewModel.useCustomGeminiTitlePrompt,
            text: $viewModel.geminiTitlePromptText,
            defaultText: GeminiPromptDefaults.titleBlock
          ),
          promptEditorConfig(
            heading: String(localized: "Card summaries"),
            description: String(localized: "Control tone and style for the summary field."),
            isEnabled: $viewModel.useCustomGeminiSummaryPrompt,
            text: $viewModel.geminiSummaryPromptText,
            defaultText: GeminiPromptDefaults.summaryBlock
          ),
          promptEditorConfig(
            heading: String(localized: "Detailed summaries"),
            description: String(
              localized: "Define the minute-by-minute breakdown format and examples."),
            isEnabled: $viewModel.useCustomGeminiDetailedPrompt,
            text: $viewModel.geminiDetailedPromptText,
            defaultText: GeminiPromptDefaults.detailedSummaryBlock
          ),
        ],
        onReset: viewModel.resetGeminiPromptOverrides
      )
    case .local:
      promptSection(
        title: String(localized: "Local prompt customization"),
        subtitle: String(localized: "Adjust the prompts used for local timeline summaries."),
        intro: String(
          localized: "Customize the local model prompts for summary and title generation."),
        sections: [
          promptEditorConfig(
            heading: String(localized: "Timeline summaries"),
            description: String(
              localized: "Control how the local model writes its 2-3 sentence card summaries."),
            isEnabled: $viewModel.useCustomOllamaSummaryPrompt,
            text: $viewModel.ollamaSummaryPromptText,
            defaultText: OllamaPromptDefaults.summaryBlock
          ),
          promptEditorConfig(
            heading: String(localized: "Card titles"),
            description: String(
              localized: "Adjust the tone and examples for local title generation."),
            isEnabled: $viewModel.useCustomOllamaTitlePrompt,
            text: $viewModel.ollamaTitlePromptText,
            defaultText: OllamaPromptDefaults.titleBlock
          ),
        ],
        onReset: viewModel.resetOllamaPromptOverrides
      )
    case .chatGPT, .claude, .openAICompatible:
      EmptyView()
    }
  }

  private var agentPromptCustomizationSection: some View {
    let defaults: (titleBlock: String, summaryBlock: String, detailedSummaryBlock: String)
    if viewModel.selectedAgentPromptProvider == .claude {
      defaults = (
        ClaudePromptDefaults.titleBlock,
        ClaudePromptDefaults.summaryBlock,
        ClaudePromptDefaults.detailedSummaryBlock
      )
    } else {
      defaults = (
        CodexPromptDefaults.titleBlock,
        CodexPromptDefaults.summaryBlock,
        CodexPromptDefaults.detailedSummaryBlock
      )
    }
    return promptSection(
      title: String(localized: "ChatGPT and Claude prompt customization"),
      subtitle: String(
        localized: "Keep independent card-generation prompts for each CLI provider."),
      intro:
        String(
          localized:
            "Overrides apply only when their toggle is on. Unchecked sections fall back to TBD's defaults."
        ),
      sections: [
        promptEditorConfig(
          heading: String(localized: "Card titles"),
          description: String(localized: "Shape how card titles read and tweak the example list."),
          isEnabled: $viewModel.useCustomAgentTitlePrompt,
          text: $viewModel.agentTitlePromptText,
          defaultText: defaults.titleBlock
        ),
        promptEditorConfig(
          heading: String(localized: "Card summaries"),
          description: String(localized: "Control tone and style for the summary field."),
          isEnabled: $viewModel.useCustomAgentSummaryPrompt,
          text: $viewModel.agentSummaryPromptText,
          defaultText: defaults.summaryBlock
        ),
        promptEditorConfig(
          heading: String(localized: "Detailed summaries"),
          description: String(
            localized: "Define the minute-by-minute breakdown format and examples."),
          isEnabled: $viewModel.useCustomAgentDetailedPrompt,
          text: $viewModel.agentDetailedPromptText,
          defaultText: defaults.detailedSummaryBlock
        ),
      ],
      onReset: viewModel.resetAgentPromptOverrides,
      showsAgentProviderPicker: true
    )
  }

  private struct PromptEditorConfig {
    let heading: String
    let description: String
    let isEnabled: Binding<Bool>
    let text: Binding<String>
    let defaultText: String
  }

  private func promptEditorConfig(
    heading: String,
    description: String,
    isEnabled: Binding<Bool>,
    text: Binding<String>,
    defaultText: String
  ) -> PromptEditorConfig {
    PromptEditorConfig(
      heading: heading, description: description, isEnabled: isEnabled, text: text,
      defaultText: defaultText)
  }

  private func promptSection(
    title: String,
    subtitle: String,
    intro: String,
    sections: [PromptEditorConfig],
    onReset: @escaping () -> Void,
    showsAgentProviderPicker: Bool = false
  ) -> some View {
    SettingsSection(title: title, subtitle: subtitle) {
      VStack(alignment: .leading, spacing: 18) {
        if showsAgentProviderPicker {
          TBDSegmented(
            selection: $viewModel.selectedAgentPromptProvider,
            options: [(LLMProviderID.chatGPT, "ChatGPT"), (LLMProviderID.claude, "Claude")]
          )
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Text("Provider"))
        }

        Text(intro)
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(sections.indices, id: \.self) { index in
          promptEditorBlock(config: sections[index])
        }

        HStack {
          Spacer()
          SettingsSecondaryButton(
            title: String(localized: "Reset to TBD defaults"),
            systemImage: "arrow.counterclockwise",
            action: onReset
          )
        }
      }
    }
  }

  /// A prompt-customization block: toggle + text-editor pair. The editor is
  /// a field brick (tile, line-strong ring) so it reads as an input.
  private func promptEditorBlock(config: PromptEditorConfig) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle(isOn: config.isEnabled) {
        VStack(alignment: .leading, spacing: 3) {
          Text(config.heading)
            .font(TBDTokens.Typography.control)
            .foregroundStyle(TBDColor.ink)
          Text(config.description)
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(TBDSwitchStyle())
      .pointingHandCursor()

      ZStack(alignment: .topLeading) {
        if config.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(config.defaultText)
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
        }

        TextEditor(text: config.text)
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(
            config.isEnabled.wrappedValue ? TBDColor.ink : TBDColor.muted
          )
          .scrollContentBackground(.hidden)
          .disabled(!config.isEnabled.wrappedValue)
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(minHeight: config.isEnabled.wrappedValue ? 140 : 120)
      }
      .background(SettingsStyle.editorFill, in: TBDBrickShape())
      .overlay(TBDBrickShape().strokeBorder(SettingsStyle.editorBorder, lineWidth: TBDKit.hair))
    }
  }
}

// MARK: - Upgrade banner
//
// Semantically this is a promotion, not configuration, so it is the one
// tinted panel on the page (teal wash). Its two actions are the kit buttons.

private struct LocalModelUpgradeBanner: View {
  let preset: LocalModelPreset
  let onKeepLegacy: () -> Void
  let onUpgrade: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles")
          .foregroundStyle(TBDColor.primaryOn)
          .padding(8)
          .background(TBDColor.primaryFill, in: TBDBrickShape())
        VStack(alignment: .leading, spacing: 4) {
          Text("Upgrade to \(preset.displayName)")
            .font(TBDTokens.Typography.title)
            .foregroundStyle(TBDColor.ink)
          Text("Upgrade to Qwen3VL for a big improvement in quality.")
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.inkSoft)
        }
        Spacer()
      }

      VStack(alignment: .leading, spacing: 6) {
        ForEach(preset.highlightBullets, id: \.self) { bullet in
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
              .font(TBDFonts.symbol(12))
              .foregroundStyle(TBDColor.tealInk)
              .padding(.top, 2)
            Text(bullet)
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.inkSoft)
          }
        }
      }

      HStack(spacing: 12) {
        Button(action: onKeepLegacy) {
          Text("Keep Qwen2.5")
        }
        .buttonStyle(TBDButtonStyle(.secondary))
        .pointingHandCursor()

        Button(action: onUpgrade) {
          HStack(spacing: 6) {
            Text("Upgrade now")
            Image(systemName: "arrow.right")
              .font(TBDFonts.symbol(12))
          }
        }
        .buttonStyle(TBDButtonStyle(.primary))
        .pointingHandCursor()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tbdPanelTint(padding: TBDKit.s5)
  }
}

// MARK: - Upgrade sheet (unchanged — it's a modal, not a settings surface)

struct LocalModelUpgradeSheet: View {
  let preset: LocalModelPreset
  let initialEngine: LocalEngine
  let initialBaseURL: String
  let initialModelId: String
  let initialAPIKey: String
  let onCancel: () -> Void
  let onUpgradeSuccess: (LocalEngine, String, String, String) -> Void

  @State private var selectedEngine: LocalEngine
  @State private var candidateBaseURL: String
  @State private var candidateModelId: String
  @State private var candidateAPIKey: String
  @State private var didApplyUpgrade = false

  init(
    preset: LocalModelPreset,
    initialEngine: LocalEngine,
    initialBaseURL: String,
    initialModelId: String,
    initialAPIKey: String,
    onCancel: @escaping () -> Void,
    onUpgradeSuccess: @escaping (LocalEngine, String, String, String) -> Void
  ) {
    self.preset = preset
    self.initialEngine = initialEngine
    self.initialBaseURL = initialBaseURL
    self.initialModelId = initialModelId
    self.initialAPIKey = initialAPIKey
    self.onCancel = onCancel
    self.onUpgradeSuccess = onUpgradeSuccess

    let startingEngine = initialEngine
    _selectedEngine = State(initialValue: startingEngine)
    _candidateBaseURL = State(
      initialValue: initialBaseURL.isEmpty ? startingEngine.defaultBaseURL : initialBaseURL)
    let recommendedModel = preset.modelId(for: startingEngine == .custom ? .ollama : startingEngine)
    _candidateModelId = State(initialValue: recommendedModel)
    _candidateAPIKey = State(initialValue: initialAPIKey)
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: true) {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 6) {
            Text("Upgrade to \(preset.displayName)")
              .font(TBDTokens.Typography.title)
              .foregroundStyle(TBDColor.ink)
            Text(
              "Follow the steps below, run a quick test, and TBD will switch you over automatically."
            )
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
          }
          Spacer()
          Button(action: onCancel) {
            Image(systemName: "xmark")
              .font(TBDFonts.symbol(14))
          }
          .buttonStyle(TBDButtonStyle(.icon))
          .pointingHandCursor()
        }

        VStack(alignment: .leading, spacing: 6) {
          ForEach(preset.highlightBullets, id: \.self) { bullet in
            HStack(spacing: 8) {
              Image(systemName: "sparkle")
                .font(TBDFonts.symbol(12))
                .foregroundStyle(TBDColor.tealInk)
              Text(bullet)
                .font(TBDTokens.Typography.body)
                .foregroundStyle(TBDColor.ink)
            }
          }
        }

        VStack(alignment: .leading, spacing: 12) {
          Text("Which local runtime are you using?")
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
          TBDSegmented(
            selection: $selectedEngine,
            options: [
              (LocalEngine.ollama, "Ollama"), (LocalEngine.lmstudio, "LM Studio"),
              (LocalEngine.custom, "Custom"),
            ]
          )
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Text("Engine"))
        }

        instructionView(for: selectedEngine)

        LocalLLMTestView(
          baseURL: $candidateBaseURL,
          modelId: $candidateModelId,
          apiKey: $candidateAPIKey,
          engine: selectedEngine,
          showInputs: true,
          buttonLabel: String(localized: "Test upgrade"),
          basePlaceholder: selectedEngine.defaultBaseURL,
          modelPlaceholder: preset.modelId(
            for: selectedEngine == .custom ? .ollama : selectedEngine),
          onTestComplete: { success in
            if success && !didApplyUpgrade {
              didApplyUpgrade = true
              onUpgradeSuccess(selectedEngine, candidateBaseURL, candidateModelId, candidateAPIKey)
            }
          }
        )

        Text(
          "Once the test succeeds, TBD updates your settings to \(preset.displayName) automatically."
        )
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)

        HStack {
          Spacer()
          SettingsSecondaryButton(title: String(localized: "Close"), action: onCancel)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(32)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(TBDColor.tile)
    .onChange(of: selectedEngine) { _, newEngine in
      candidateModelId = preset.modelId(for: newEngine == .custom ? .ollama : newEngine)
      if newEngine != .custom {
        candidateBaseURL = newEngine.defaultBaseURL
        candidateAPIKey = ""
      }
    }
  }

  @ViewBuilder
  private func instructionView(for engine: LocalEngine) -> some View {
    let instruction = preset.instructions(for: engine == .custom ? .ollama : engine)
    VStack(alignment: .leading, spacing: 12) {
      Text(instruction.title)
        .font(TBDFonts.nunito(TBDKit.textLabel, TBDKit.weightLabel))
        .foregroundStyle(TBDColor.ink)
      Text(instruction.subtitle)
        .font(TBDTokens.Typography.hint)
        .foregroundStyle(TBDColor.muted)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(instruction.bullets.enumerated()), id: \.offset) { index, bullet in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
              .frame(width: 22, alignment: .leading)
            Text(bullet)
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.ink)
          }
        }
      }

      if let command = instruction.command,
        let commandTitle = instruction.commandTitle,
        let commandSubtitle = instruction.commandSubtitle
      {
        TerminalCommandView(
          title: commandTitle,
          subtitle: commandSubtitle,
          command: command
        )
      }

      if let buttonTitle = instruction.buttonTitle,
        let url = instruction.buttonURL
      {
        SettingsPrimaryButton(
          title: buttonTitle,
          systemImage: "arrow.down.circle.fill",
          prominent: false,
          action: { NSWorkspace.shared.open(url) }
        )
      }

      if let note = instruction.note {
        Text(note)
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .tbdCard()
  }
}
