//
//  SettingsConnectorsTabView.swift
//  TBD
//
//  Settings › Connectors (dev.16, C280 C11, DESIGN-CONNECTORS §4, §10): the gate in plain words, the accounts Connect lets
//  TBD's agent use (read only here), and the person's remembered choices for TBD's agent. Accounts are connected and
//  shared in Connect, never here: the two buttons open Connect through the Portal launcher in the system browser. TBD does
//  not open a launch session itself. The pane reads through `ConnectorsStore` (refresh rules are there).
//

import AppKit
import SwiftUI
import TBDDesign
import TBDModels

/// The Portal address and workspace the Connect links use: the active profile's issuer and the active workspace.
@MainActor
struct ConnectorsPortal {
  var issuer: @MainActor () -> String
  var workspace: @MainActor () -> String

  static let live = ConnectorsPortal(
    issuer: { TBDAccountCoordinator.shared.profiles.first { $0.id == TBDAccountCoordinator.shared.activeProfile }?.issuer ?? "" },
    workspace: { TBDAccountCoordinator.shared.activeWorkspace })

  /// "Manage in Connect" (`newAccount` false) or "Connect a new account" (true); nil without a Portal address and workspace.
  func connectLink(newAccount: Bool) -> URL? {
    TBDConnectors.connectLink(issuer: issuer(), workspace: workspace(), newAccount: newAccount)
  }

  /// The person's own Portal (Open Portal).
  var portalURL: URL { TBDConnectors.portalURL(issuer: issuer()) }
}

struct SettingsConnectorsTabView: View {
  @ObservedObject private var store: ConnectorsStore
  /// The Portal links also depend on the account: observe it so the buttons follow a workspace change.
  @ObservedObject private var account = TBDAccountCoordinator.shared
  private let portal: ConnectorsPortal
  @State private var removeFailed = false

  @MainActor
  init(store: ConnectorsStore? = nil, portal: ConnectorsPortal = .live) {
    _store = ObservedObject(wrappedValue: store ?? .shared)
    self.portal = portal
  }

  var body: some View {
    let state = store.state
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      if state.gate == .active {
        accountsSection(state)
      } else {
        gateSection(state.gate)
      }
      if state.gate == .active || !state.choices.isEmpty {
        choicesSection(state)
      }
    }
    .background(AgentWallWindowObserver { visible in store.windowVisibilityChanged(visible) })
    .onAppear { store.pageDidAppear() }
    .onDisappear { store.pageDidDisappear() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.appDidBecomeActive()
    }
  }

  // MARK: Gate

  private func gateSection(_ gate: TBDConnectorsGate) -> some View {
    SettingsSection(title: "", isFirst: true) {
      VStack(alignment: .leading, spacing: TBDKit.s4) {
        if let message = gate.message {
          switch gate {
          case .locked: TBDAvailableWith(message)
          case .failed: TBDNotice(message, tone: .needsYou)
          default: TBDNotice(message, tone: .neutral)
          }
        }
        switch gate.action {
        case .none: EmptyView()
        case .openPortal:
          Button("Open Portal") { NSWorkspace.shared.open(portal.portalURL) }
            .buttonStyle(TBDButtonStyle(.primary))
            .pointingHandCursor()
        case .connectAgent:
          // The existing action: the setup's TBD's agent step pairs the agent with the workspace in the browser.
          Button("Connect TBD's agent") {
            NotificationCenter.default.post(name: .tbdOpenOnboarding, object: TBDOnboardingStep.agent.rawValue)
          }
          .buttonStyle(TBDButtonStyle(.primary))
          .pointingHandCursor()
        case .signIn:
          Button("Go to Account") { NotificationCenter.default.post(name: .openAccountSettings, object: nil) }
            .buttonStyle(TBDButtonStyle(.primary))
            .pointingHandCursor()
        }
        if case .failed = gate {
          Button("Try again") { Task { await store.refresh() } }
            .buttonStyle(TBDButtonStyle(.quiet))
            .pointingHandCursor()
        }
      }
    }
  }

  // MARK: Accounts

  private func accountsSection(_ state: ConnectorsState) -> some View {
    SettingsSection(
      title: TBDConnectors.accountsTitle,
      subtitle: "Connect decides what TBD's agent can do with each account. Change it in Connect, not here.",
      isFirst: true,
      trailing: {
        Button("Refresh") { Task { await store.refresh() } }
          .buttonStyle(TBDButtonStyle(.quiet))
          .disabled(store.isRefreshing)
          .pointingHandCursor()
      }
    ) {
      VStack(alignment: .leading, spacing: TBDKit.s4) {
        if let notice = state.notice { TBDNotice(notice, tone: .needsYou) }
        if state.accounts.isEmpty {
          TBDNotice(TBDConnectors.emptyAccountsLine, tone: .neutral)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.accounts.enumerated()), id: \.element.id) { index, item in
              accountRow(item, last: index == state.accounts.count - 1)
            }
          }
          if TBDConnectors.showsReadOnlyHint(state.accounts) {
            TBDNotice(TBDConnectors.readOnlyHint, tone: .neutral)
          }
        }
        HStack(spacing: TBDKit.s3) {
          linkButton("Manage in Connect", newAccount: false, prominent: true)
          linkButton("Connect a new account", newAccount: true, prominent: false)
        }
      }
    }
  }

  private func accountRow(_ item: TBDConnectorAccount, last: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: TBDKit.s4) {
        Text(String(item.serviceName.prefix(1)).uppercased())
          .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightLabel))
          .foregroundStyle(TBDColor.ink)
          .frame(width: 36, height: 36)
          .background(TBDColor.plate, in: TBDBrickShape())
          .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.label)
            .font(TBDTokens.Typography.control)
            .foregroundStyle(TBDColor.ink)
            .fixedSize(horizontal: false, vertical: true)
          Text("\(item.serviceName) · \(item.kind.words)")
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
        }
        Spacer(minLength: TBDKit.s3)
        TBDTag(item.access.words, status: .idle)
      }
      .padding(.vertical, SettingsStyle.rowVerticalPadding)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(Text("\(item.label), \(item.serviceName), \(item.kind.words), \(item.access.words)"))
      if !last { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
    }
  }

  @ViewBuilder
  private func linkButton(_ title: String, newAccount: Bool, prominent: Bool) -> some View {
    let url = portal.connectLink(newAccount: newAccount)
    SettingsPrimaryButton(title: title, systemImage: "arrow.up.right", isDisabled: url == nil, prominent: prominent) {
      if let url { NSWorkspace.shared.open(url) }
    }
  }

  // MARK: Remembered choices

  private func choicesSection(_ state: ConnectorsState) -> some View {
    SettingsSection(
      title: TBDConnectors.choicesTitle,
      subtitle: TBDConnectors.choicesNote,
      isFirst: state.gate != .active
    ) {
      VStack(alignment: .leading, spacing: TBDKit.s3) {
        if state.choices.isEmpty {
          Text(TBDConnectors.noChoicesLine)
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.choices.enumerated()), id: \.element.id) { index, choice in
              choiceRow(choice, last: index == state.choices.count - 1)
            }
          }
        }
        if removeFailed {
          TBDNotice("TBD could not forget that choice. Try again.", tone: .needsYou)
        }
      }
    }
  }

  private func choiceRow(_ choice: TBDConnectorChoice, last: Bool) -> some View {
    SettingsRow(label: choice.text, showsDivider: !last) {
      Button("Remove") {
        Task { removeFailed = !(await store.remove(choice)) }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      .pointingHandCursor()
      .accessibilityLabel(Text("Remove: \(choice.text)"))
    }
  }
}
