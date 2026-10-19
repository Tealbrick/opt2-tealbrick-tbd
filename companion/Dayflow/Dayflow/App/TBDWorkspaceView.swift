import SwiftUI
import AppKit
import TBDDesign
import TBDListening
import TBDModels

/// Navigation owns visibility only. Capture services remain owned by the app lifecycle.
struct TBDWorkspaceView<Companion: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  @AppStorage("tbd.portalInvitationDismissed") private var invitationDismissed = false
  @ObservedObject private var account = TBDAccountCoordinator.shared
  @State private var settingsSection: String?
  @State private var selection: Section = .companion
  @StateObject private var chat = TBDChatRuntime.shared
  @StateObject private var listening = TBDListeningRuntime.shared
  private let companion: Companion

  init(@ViewBuilder companion: () -> Companion) {
    self.companion = companion()
  }

  private enum Section: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case companion = "Companion"
    case listening = "Listening"
    /// What the person reads (C142: the aspect is "Listen"); the raw value stays the stored/test identifier.
    var title: String { self == .listening ? "Listen" : rawValue }
    var id: String { rawValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Global navigation: kit side-nav look (tab pairs, 36pt bricks) as a top rail.
      HStack(spacing: TBDKit.s3) {
        ForEach(Section.allCases.filter { $0 != .chat || account.signedIn }) { section in
          let selected = selection == section
          Button { settingsSection = nil; selection = section } label: {
            Text(section.title)
              .frame(minWidth: 112 - 2 * TBDKit.s3)
          }
          .buttonStyle(TBDRailTabStyle(current: selected))
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("tbd.workspace." + section.rawValue.lowercased())
        }
      }
      .frame(maxWidth: .infinity)
      .onAppear { TBDTitleBarAction.install() }
      .overlay(alignment: .trailing) {
        HStack(spacing: TBDKit.s2) {
          Button {
            settingsSection = settingsSection == nil ? "account" : nil
          } label: {
            Image(systemName: "gearshape").font(TBDFonts.symbol(TBDKit.textControl))
              .frame(minWidth: 36, minHeight: 36)
          }
          .buttonStyle(TBDRailTabStyle(current: settingsSection != nil, square: true))
          .help("Settings").accessibilityLabel("Settings")
          Button {
            appearance = colorScheme == .dark ? .light : .dark
          } label: {
            Image(systemName: colorScheme == .dark ? "sun.max" : "moon")
              .font(TBDFonts.symbol(TBDKit.textControl))
              .frame(minWidth: 36, minHeight: 36)
          }
          .buttonStyle(TBDButtonStyle(.icon))
          .help(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
          .accessibilityLabel(colorScheme == .dark ? "Switch to light mode" : "Switch to dark mode")
          .accessibilityIdentifier("tbd.appearance.toggle")
        }
        .padding(.trailing, 18)
      }
      .padding(.top, 10)
      .padding(.bottom, 12)
      .background(TBDColor.paper)
      .overlay(alignment: .bottom) { Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair) }
      if account.hasCheckedSession && !account.signedIn && !invitationDismissed && settingsSection == nil {
        HStack(spacing: 12) {
          Text("Connect to Portal to use Chat and remote agents. Companion and Listen work without an account.")
            .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
          Spacer()
          Button("Sign in") { settingsSection = "account" }.buttonStyle(TBDButtonStyle(.secondary))
          Button("Not now") { invitationDismissed = true }.buttonStyle(TBDButtonStyle(.quiet))
        }.padding(.horizontal, 20).padding(.vertical, 8)
      }
      ZStack {
        // Retain the existing view tree and its navigation state across tab switches.
        companion
          .opacity(selection == .companion && settingsSection == nil ? 1 : 0)
          .allowsHitTesting(selection == .companion && settingsSection == nil)
          .disabled(selection != .companion || settingsSection != nil)
          .accessibilityHidden(selection != .companion || settingsSection != nil)

        if account.signedIn {
        ZStack {
          TBDChatView()
          if !chat.status.isEmpty { pending("Chat", detail: chat.status) }
          if !chat.notice.isEmpty {
            Text(chat.notice)
              .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.ink)
              .padding(.horizontal, 14).padding(.vertical, 8)
              .tbdFloating()
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
              .padding(.top, 10)
              .allowsHitTesting(false)
          }
        }
        .opacity(selection == .chat && settingsSection == nil ? 1 : 0)
        .allowsHitTesting(selection == .chat && settingsSection == nil)
        .disabled(selection != .chat || settingsSection != nil)
        .accessibilityHidden(selection != .chat || settingsSection != nil)
        }
        listening.content()
          .opacity(selection == .listening && settingsSection == nil ? 1 : 0)
          .allowsHitTesting(selection == .listening && settingsSection == nil)
          .disabled(selection != .listening || settingsSection != nil)
          .accessibilityHidden(selection != .listening || settingsSection != nil)

        if let section = settingsSection {
          SettingsView(initialSection: section)
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TBDColor.paper)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .ignoresSafeArea(.container, edges: .top)
    .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
    .tint(TBDColor.tealInk)
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("tbdOpenSettings"))) { note in
      settingsSection = note.object as? String ?? "account"
    }
    .onChange(of: account.signedIn) { _, signedIn in
      if !signedIn && selection == .chat { selection = .companion }
    }
    .task {
      listening.activate = { selection = .listening }
      // "Save to Knowledge": through the Chat helper as TBD's own agent; needs a signed-in person.
      listening.saveToKnowledge = { request, status in
        guard TBDAccountCoordinator.shared.signedIn else { throw TBDKnowledgeError.signIn }
        return try await TBDChatRuntime.shared.knowledgeSave(request, onStatus: status)
      }
      listening.start()
      await account.refresh()
      await refreshEntitlements()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(10)) } catch { return }
        await account.refresh()
        await refreshEntitlements()
      }
    }
  }

  /// C282: functions unlock with what the workspace paid for. The helper caches the read (10 min, or a new
  /// workspace), so this 10-second call is cheap; a failed read keeps the helper's last good snapshot.
  private func refreshEntitlements() async {
    guard TBDAccountCoordinator.shared.signedIn else {
      listening.knowledgeAvailability = TBDKnowledgeError.signIn.errorDescription
      return
    }
    let value = try? await TBDChatRuntime.shared.accountCall("entitlements")
    listening.knowledgeAvailability = TBDEntitlements(helperValue: value).availability(.knowledge)
  }


  private func pending(_ title: String, detail: String) -> some View {
    VStack(spacing: 12) {
      Text(title).font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      Text(detail).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Top-rail tab: the kit side-nav item look (36pt brick, tab pairs), centred. Current = ink fill with paper text.
private struct TBDRailTabStyle: ButtonStyle {
  let current: Bool
  var square = false
  func makeBody(configuration: Configuration) -> some View {
    TBDRailTabBody(current: current, square: square, configuration: configuration)
  }
}

private struct TBDRailTabBody: View {
  let current: Bool
  let square: Bool
  let configuration: ButtonStyleConfiguration
  @State private var hovered = false
  @Environment(\.isFocused) private var focused
  var body: some View {
    let hover = hovered || configuration.isPressed
    let fill = current ? (hover ? TBDColor.tabCurrentHoverFill : TBDColor.tabCurrentFill) : (hover ? TBDColor.tabHoverFill : TBDColor.tabFill)
    let on = current ? (hover ? TBDColor.tabCurrentHoverOn : TBDColor.tabCurrentOn) : (hover ? TBDColor.tabHoverOn : TBDColor.tabOn)
    configuration.label
      .font(TBDFonts.nunito(TBDKit.textControl, current ? TBDKit.weightLabel : TBDKit.weightNav))
      .lineLimit(1)
      .foregroundStyle(on)
      .padding(.horizontal, square ? 0 : TBDKit.s3)
      .frame(minHeight: TBDTokens.Control.minHeight)
      .background(fill, in: TBDBrickShape())
      .contentShape(TBDBrickShape())
      .tbdFocusRing(focused, offset: TBDKit.focusOffsetTight)
      .onHover { hovered = $0 }
  }
}

@MainActor
enum TBDTitleBarAction {
  /// Height of the navbar strip that acts as the title bar (top padding + glass + bottom padding).
  static let stripHeight: CGFloat = 56
  private static var monitor: Any?

  /// AppKit's hidden title bar swallows clicks in the top strip before SwiftUI sees them,
  /// and SwiftUI turns the native zoom into a no-op. Catch title-bar double-clicks at the
  /// window level, outside the traffic lights, the section tabs and the trailing buttons.
  static func install() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
      guard event.clickCount == 2, let window = event.window, window.identifier?.rawValue.contains("main") == true || window.title == "TBD",
            let content = window.contentView else { return event }
      let p = event.locationInWindow, width = content.bounds.width
      let inStrip = p.y >= content.bounds.height - stripHeight
      let onTrafficLights = p.x < 80
      let onTabs = abs(p.x - width / 2) < 200
      let onTrailingButtons = p.x > width - 110
      guard inStrip, !onTrafficLights, !onTabs, !onTrailingButtons else { return event }
      perform(window)
      return nil
    }
  }

  static func perform(_ target: NSWindow? = nil) {
    guard let window = target ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.miniaturize(nil)
    case "None": break
    default: toggleFill(window)  // "Maximize"/"Fill"/unset: fill the screen, not full-screen mode.
    }
  }

  /// SwiftUI windows zoom to their content's ideal size (a no-op here), so fill the
  /// screen's visible frame directly and restore the previous frame on the next double-click.
  private static var restoreFrames: [ObjectIdentifier: NSRect] = [:]
  private static func toggleFill(_ window: NSWindow) {
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
    let key = ObjectIdentifier(window)
    let filled = abs(window.frame.width - visible.width) < 2 && abs(window.frame.height - visible.height) < 2
    if filled, let previous = restoreFrames[key] {
      window.setFrame(previous, display: true, animate: true)
      restoreFrames[key] = nil
    } else {
      restoreFrames[key] = window.frame
      window.setFrame(visible, display: true, animate: true)
    }
  }
}
