//
//  SettingsAgentAccessTabView.swift
//  Dayflow
//
//  The "Tools" tab: the MCP config snippet to copy, the "Allow edits" switch,
//  and the optional `dayflow` terminal command. TBD never edits another app's
//  configuration: the snippet is copy-only.
//

import AppKit
import SwiftUI
import TBDDesign

struct SettingsAgentAccessTabView: View {
  @ObservedObject var viewModel: AgentAccessViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsStyle.sectionSpacing) {
      mcpSection
      editsSection
      terminalSection
    }
    .onAppear { viewModel.refresh() }
  }

  private var mcpSection: some View {
    SettingsSection(
      title: String(localized: "Connect to AI tools"),
      subtitle:
        String(
          localized:
            "Let Codex, Claude, Cursor, and other AI tools read your TBD timeline. Copy the entry below and paste it into the MCP configuration of the tool you use. TBD never changes another app's settings. Nothing leaves your Mac except what you send in your own conversations."
        ),
      isFirst: true
    ) {
      SettingsRow(
        label: String(localized: "MCP config"),
        subtitle: String(localized: "Paste this into any MCP client's configuration."),
        showsDivider: false
      ) {
        SettingsSecondaryButton(
          title: viewModel.copiedSnippet
            ? String(localized: "Copied") : String(localized: "Copy config"),
          systemImage: viewModel.copiedSnippet ? "checkmark" : "doc.on.doc"
        ) {
          viewModel.copySnippet()
        }
      }
    }
  }

  private var editsSection: some View {
    SettingsSection(
      title: String(localized: "Allow edits"),
      subtitle:
        String(
          localized:
            "Off means AI tools can read your timeline but never change it. On lets them rename activities, manage categories, and set day goals. Deleting anything always asks you first, and every edit is logged."
        )
    ) {
      VStack(alignment: .leading, spacing: 0) {
        SettingsRow(
          label: viewModel.editsEnabled
            ? String(localized: "Edits are on") : String(localized: "Edits are off"),
          subtitle: viewModel.editsEnabled
            ? String(localized: "AI tools can make changes through TBD while it's running.")
            : nil,
          showsDivider: false
        ) {
          SettingsToggle(isOn: $viewModel.editsEnabled)
        }
      }
    }
  }

  private var terminalSection: some View {
    SettingsSection(
      title: String(localized: "Terminal command"),
      subtitle:
        String(
          localized:
            "Adds a `dayflow` command so you can see your timeline from any terminal. This isn't a separate package like an npm install: it links to the CLI already inside TBD, so the CLI always stays in sync with the app and can't break when the app updates. Nothing is downloaded and your shell configuration isn't touched."
        )
    ) {
      VStack(alignment: .leading, spacing: 12) {
        SettingsRow(
          label: terminalStatusLabel,
          subtitle: terminalStatusSubtitle,
          showsDivider: false
        ) {
          SettingsSecondaryButton(title: terminalActionTitle) {
            viewModel.toggleTerminalCommand()
          }
        }

        if let error = viewModel.terminalError {
          TBDNotice(error, tone: .needsYou)
        }

        SettingsCommandBlock(
          command: viewModel.manualTerminalInstallCommand,
          copied: viewModel.copiedTerminalCommand,
          copy: viewModel.copyTerminalCommand
        )
      }
    }
  }

  private var terminalStatusLabel: String {
    switch viewModel.terminalStatus {
    case .installed: return String(localized: "Installed")
    case .notInstalled: return String(localized: "Not installed")
    case .pointsElsewhere: return String(localized: "Points elsewhere")
    }
  }

  private var terminalStatusSubtitle: String? {
    switch viewModel.terminalStatus {
    case .installed:
      return String(localized: "Try: dayflow timeline")
    case .notInstalled:
      return nil
    case .pointsElsewhere(let target):
      if let target {
        return String(
          localized: "\(CompanionTools.defaultTerminalLinkPath) links to \(target), not this app.")
      }
      return String(
        localized:
          "\(CompanionTools.defaultTerminalLinkPath) is a file that TBD didn't create. It is left unchanged."
      )
    }
  }

  private var terminalActionTitle: String {
    switch viewModel.terminalStatus {
    case .installed: return String(localized: "Remove")
    case .notInstalled: return String(localized: "Install")
    case .pointsElsewhere: return String(localized: "Replace")
    }
  }
}

private struct SettingsCommandBlock: View {
  let command: String
  let copied: Bool
  let copy: () -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Text(command)
        .font(TBDFonts.mono(12))
        .foregroundStyle(TBDColor.inkSoft)
        .textSelection(.enabled)
        .padding(.leading, 14)
        .padding(.trailing, 104)
        .padding(.vertical, 13)
        .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(TBDColor.tile, in: TBDBrickShape())
    .overlay(
      TBDBrickShape()
        .strokeBorder(TBDColor.line, lineWidth: TBDKit.hair)
    )
    .overlay(alignment: .trailing) {
      Button(action: copy) {
        HStack(spacing: 5) {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(TBDFonts.symbol(11))
          Text(copied ? String(localized: "Copied") : String(localized: "Copy"))
        }
      }
      .buttonStyle(TBDButtonStyle(.secondary))
      .pointingHandCursor()
      .accessibilityLabel(
        copied
          ? String(localized: "Terminal command copied")
          : String(localized: "Copy terminal command")
      )
      .padding(.trailing, 6)
    }
  }
}

// MARK: - View model

@MainActor
final class AgentAccessViewModel: ObservableObject {
  @Published var copiedSnippet = false
  @Published var copiedTerminalCommand = false
  @Published var terminalStatus: CompanionTools.TerminalCommandStatus = .notInstalled
  @Published var terminalError: String?

  /// Takes effect immediately: the agent write socket opens or closes as the
  /// switch moves, no restart. The server also re-checks the flag on every
  /// request, so turning it off blocks writes even mid-session.
  @Published var editsEnabled: Bool = AgentAccessPreferences.editsEnabled {
    didSet {
      guard editsEnabled != AgentAccessPreferences.editsEnabled else { return }
      AgentAccessPreferences.editsEnabled = editsEnabled
      if editsEnabled {
        AgentBridgeServer.shared.start()
      } else {
        AgentBridgeServer.shared.stop()
      }
    }
  }

  private var helperPath: String {
    CompanionTools.helperPath(bundleURL: Bundle.main.bundleURL)
  }

  var manualTerminalInstallCommand: String {
    CompanionTools.manualInstallCommand(helperPath: helperPath)
  }

  func refresh() {
    // Keep the switch and the socket in step with the stored flag.
    editsEnabled = AgentAccessPreferences.editsEnabled
    if editsEnabled {
      AgentBridgeServer.shared.start()
    } else {
      AgentBridgeServer.shared.stop()
    }
    terminalStatus = CompanionTools.terminalCommandStatus(expectedHelperPath: helperPath)
  }

  func copySnippet() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      CompanionTools.mcpConfigSnippet(helperPath: helperPath), forType: .string)
    copiedSnippet = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.copiedSnippet = false
    }
  }

  func copyTerminalCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(manualTerminalInstallCommand, forType: .string)
    copiedTerminalCommand = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.copiedTerminalCommand = false
    }
  }

  func toggleTerminalCommand() {
    terminalError = nil
    switch terminalStatus {
    case .installed:
      CompanionTools.removeTerminalCommand()
    case .notInstalled, .pointsElsewhere:
      do {
        try CompanionTools.installTerminalCommand(helperPath: helperPath)
      } catch CompanionTools.TerminalCommandError.occupiedByFile {
        terminalError = String(
          localized:
            "A file that TBD didn't create is already at \(CompanionTools.defaultTerminalLinkPath). It was left unchanged."
        )
      } catch {
        terminalError = String(
          localized:
            "Automatic install failed because /usr/local/bin requires administrator access on this Mac. Copy the command below and run it in Terminal."
        )
      }
    }
    refresh()
  }
}
