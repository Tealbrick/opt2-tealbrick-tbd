//
//  SettingsView.swift
//  Dayflow
//
//  Settings screen with onboarding-inspired styling and split layout
//

import Foundation
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels

struct SettingsView: View {

  private enum SettingsTab: String, CaseIterable, Identifiable {
    case account, about
    case permissions
    case storage
    case privacy
    case providers
    case aiTools
    case data
    case other
    case capture, engine, audioAI, audioSystem

    var id: String { rawValue }

    var symbol: String {
      switch self {
      case .about: return "info.circle"
      case .account: return "person.crop.circle"
      case .permissions: return "lock.shield"
      case .storage: return "internaldrive"
      case .privacy: return "eye.slash"
      case .providers: return "network"
      case .aiTools: return "wrench.and.screwdriver"
      case .data: return "square.and.arrow.up"
      case .other: return "slider.horizontal.3"
      case .capture: return "mic"
      case .engine: return "cpu"
      case .audioAI: return "waveform"
      case .audioSystem: return "gearshape"
      }
    }
  }

  @State private var selectedTab: SettingsTab
  init(initialSection: String = "account") {
    _selectedTab = State(initialValue: SettingsTab(rawValue: initialSection) ?? .account)
  }
  private var listeningSection: String? {
    switch selectedTab {
    case .capture: return TBDListeningSettingsSection.capture.rawValue
    case .engine: return nil
    case .audioAI: return nil
    case .audioSystem: return TBDListeningSettingsSection.system.rawValue
    default: return nil
    }
  }

  @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared

  @StateObject private var storageViewModel = StorageSettingsViewModel()
  @StateObject private var privacyViewModel = RecordingPrivacySettingsViewModel()
  @StateObject private var providersViewModel = ProvidersSettingsViewModel()
  @StateObject private var otherViewModel = OtherSettingsViewModel()
  @StateObject private var agentAccessViewModel = AgentAccessViewModel()

  var body: some View {
    contentWithSheets
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("tbdListeningSettingsTabChanged"))) { note in
        guard listeningSection != nil, let section = note.object as? String else { return }
        selectedTab = section == "ai" ? .audioAI : section == "system" ? .audioSystem : SettingsTab(rawValue: section) ?? .capture
      }
  }

  private var contentWithSheets: some View {
    contentWithLifecycle
      .sheet(
        item: Binding(
          get: {
            providersViewModel.setupModalProvider.map {
              ProviderSetupWrapper(providerID: $0)
            }
          },
          set: { wrapper in
            if let wrapper {
              providersViewModel.setupModalProvider = wrapper.providerID
            } else {
              providersViewModel.cancelProviderSetup()
            }
          }
        )
      ) { wrapper in
        LLMProviderSetupView(
          providerType: wrapper.providerID,
          onBack: { providersViewModel.cancelProviderSetup() },
          onComplete: { configuredProviderID in
            let succeeded = providersViewModel.handleProviderSetupCompletion(configuredProviderID)
            if succeeded {
              providersViewModel.cancelProviderSetup()
            }
            return succeeded
          }
        )
        .frame(minWidth: 900, minHeight: 650)
      }
      .sheet(isPresented: $providersViewModel.isShowingLocalModelUpgradeSheet) {
        LocalModelUpgradeSheet(
          preset: .qwen3VL4B,
          initialEngine: providersViewModel.localEngine,
          initialBaseURL: providersViewModel.localBaseURL,
          initialModelId: providersViewModel.localModelId,
          initialAPIKey: providersViewModel.localAPIKey,
          onCancel: { providersViewModel.isShowingLocalModelUpgradeSheet = false },
          onUpgradeSuccess: { engine, baseURL, modelId, apiKey in
            providersViewModel.handleUpgradeSuccess(
              engine: engine, baseURL: baseURL, modelId: modelId, apiKey: apiKey)
            providersViewModel.isShowingLocalModelUpgradeSheet = false
          }
        )
        .frame(minWidth: 720, minHeight: 560)
      }
  }

  private var contentWithLifecycle: some View {
    GeometryReader { proxy in
      mainContent
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
    }
    .onAppear {
      providersViewModel.handleOnAppear()
      storageViewModel.refreshStorageIfNeeded(isStorageTab: selectedTab == .storage)
      launchAtLoginManager.refreshStatus()
    }
    .onChange(of: selectedTab) { _, newValue in
      if newValue == .storage {
        storageViewModel.refreshStorageIfNeeded(isStorageTab: true)
      } else if newValue == .privacy {
        privacyViewModel.handleOnAppear()
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openProvidersSettings)) { _ in
      guard selectedTab != .providers else { return }
      withAnimation(TBDMotion.quick) {
        selectedTab = .providers
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .openAccountSettings)) { _ in
      guard selectedTab != .account else { return }
      withAnimation(TBDMotion.quick) {
        selectedTab = .account
      }
    }
  }

  private var mainContent: some View {
    HStack(alignment: .top, spacing: 0) {
      sidebar
      settingsContent
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TBDColor.tile, in: TBDBrickShape())
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .padding(.trailing, TBDKit.s4)
        .padding(.bottom, TBDKit.s4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(TBDColor.paper)
  }

  /// The side-nav item of the open pane (Models covers "engine", "providers" and "audioAI").
  private var currentItem: TBDSettingsRoute.Item {
    TBDSettingsRoute.item(for: selectedTab.rawValue) ?? .account
  }

  /// One column for every pane (TBD-UX-01): the pane header, then the pane, using the tile width up to
  /// TBDMetrics.settingsContentMax and centred beyond it.
  private var settingsContent: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      SettingsPaneHeader(title: currentItem.title, subtitle: currentItem.subtitle)
        .padding(.top, TBDKit.s6)
      pane
    }
    .frame(maxWidth: TBDMetrics.settingsContentMax, maxHeight: .infinity, alignment: .topLeading)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private var pane: some View {
    if let page = TBDSettingsRoute.modelsPage(for: selectedTab.rawValue) {
      // One Models pane; each old entry point opens its own page (agent and task routes, speech, providers).
      TBDModelsView(
        screenSettings: { AnyView(SettingsProvidersTabView(viewModel: providersViewModel)) },
        initialPage: page
      )
        .id(selectedTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if let section = listeningSection {
      TBDListeningRuntime.shared.settingsContent(section: section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else if selectedTab == .privacy {
      VStack(alignment: .leading, spacing: 24) {
        tabContent
      }
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 24) {
          tabContent
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  /// One plain list, one item per pane (TBD-UX-01; v1 had one Models item). Updates live in About.
  private var sidebar: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: TBDKit.s5) {
        ForEach(TBDSettingsRoute.groups, id: \.title) { group in
          TBDNavSection(group.title) {
            ForEach(group.items, id: \.self) { item in
              let tab = SettingsTab(rawValue: item.section) ?? .account
              TBDNavItem(item.title, symbol: tab.symbol, current: currentItem == item, ringed: false) {
                withAnimation(TBDMotion.quick) { selectedTab = tab }
              }
              .pointingHandCursor()
            }
          }
        }
      }
      .padding(.top, TBDKit.s5)
      .padding(.horizontal, TBDKit.s3)
      .padding(.bottom, TBDKit.s4)
    }
    .frame(width: 208)
  }

  @ViewBuilder
  private var tabContent: some View {
    // Content swap is a pure fade. The sidebar rail item's left ink bar
    // carries the "where you went" signal — the content doesn't need to
    // redundantly slide horizontally, which implied a carousel that doesn't
    // actually exist (the sidebar is vertical, not left/right tabs).
    Group {
      switch selectedTab {
      case .about:
        TBDAboutView()
      case .account:
        SettingsAccountSection()
      case .permissions:
        TBDPermissionsView()
      case .storage:
        SettingsStorageTabView(viewModel: storageViewModel)
      case .privacy:
        SettingsRecordingPrivacyTabView(viewModel: privacyViewModel)
      case .providers:
        SettingsProvidersTabView(viewModel: providersViewModel)
      case .aiTools:
        SettingsAgentAccessTabView(viewModel: agentAccessViewModel)
      case .data:
        SettingsDataTabView(viewModel: otherViewModel)
      case .capture, .engine, .audioAI, .audioSystem:
        EmptyView()
      case .other:
        SettingsOtherTabView(viewModel: otherViewModel, launchAtLoginManager: launchAtLoginManager)
      }
    }
    .id(selectedTab)
    .transition(.opacity)
  }
}

private struct ProviderSetupWrapper: Identifiable {
  let providerID: LLMProviderID

  var id: String { providerID.rawValue }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
      .frame(width: 1400, height: 860)
  }
}
