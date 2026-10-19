//
//  DayflowApp.swift
//  TBD host app entry point.
//

import SwiftUI
import TBDDesign

struct AppRootView: View {
  @AppStorage("didOnboard") private var didOnboard = false
  @EnvironmentObject private var categoryStore: CategoryStore
  @State private var goalFlowPresentation: DayGoalFlowPresentation? = nil
  @ObservedObject private var onboarding = TBDOnboardingController.shared

  var body: some View {
    ZStack {
      // WP-ONB (C285): the first-launch flow sets every prerequisite BEFORE the person enters the app, and a
      // missing-dependency link reopens it at its step. It replaces the whole window (no rail, no Settings).
      if onboarding.isShowing {
        TBDOnboardingView()
      } else {
      TBDWorkspaceView {
        Group {
          if didOnboard { MainView(goalFlowPresentation: $goalFlowPresentation) }
          else { TBDCompanionSetup() }
        }
        .environmentObject(AppState.shared)
        .environmentObject(categoryStore)
      }
      }

      goalFlowOverlay
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private var goalFlowOverlay: some View {
    if let goalFlowPresentation {
      DayGoalFlowOverlay(
        presentation: goalFlowPresentation,
        onDismiss: {
          withAnimation(TBDMotion.spring) {
            self.goalFlowPresentation = nil
          }
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .ignoresSafeArea()
      .transition(.opacity.combined(with: .scale(scale: 0.985)))
      .zIndex(3)
    }
  }
}

@main
struct DayflowApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @AppStorage("didOnboard") private var didOnboard = false
  @StateObject private var systemAppearance = SystemAppearanceObserver()
  @AppStorage(DayflowAppearance.storageKey) private var appearance: DayflowAppearance = .system
  /// Mirrors FlowNudgeVariant.current so the menu title re-renders on toggle.
  @AppStorage(FlowNudgeVariant.defaultsKey) private var flowNudgeVariant = FlowNudgeVariant.side.rawValue
  // Must be the shared instance: the Companion CLI write path (AgentWriteHandlers)
  // writes to CategoryStore.shared; a second copy would overwrite those edits.
  @StateObject private var categoryStore = CategoryStore.shared

  init() {
    // Writing to stdout after its reader has gone away raises SIGPIPE; ignore it.
    signal(SIGPIPE, SIG_IGN)
    #if DEBUG
      // TBD Dev only: `--design-shots <dir>` renders companion screens to PNG and exits before any scene,
      // AppDelegate launch work, capture, hotkey or network starts (TBDDesignShotsMode.swift).
      if TBDDesignShots.isRequested { MainActor.assumeIsolated { TBDDesignShots.run() } }
    #endif
  }

  var body: some Scene {
    Window("TBD", id: "main") {
      AppRootView()
        .environmentObject(categoryStore)
        .background {
          MainWindowRegistrationView()
          if didOnboard {
            DayflowWindowBackground()
              .ignoresSafeArea()
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        // Use an explicit scheme even for System; clearing an override can lag until focus changes. The
        // onboarding flow has light and dark designs (C286), so it follows the appearance too.
        .preferredColorScheme(appearance.colorScheme(system: systemAppearance.colorScheme))
        .resolveDayflowTheme()
        .resolveStylePreview()
        .onAppear { dispatchPendingNotificationNavigation(after: 0.1) }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
          dispatchPendingNotificationNavigation(after: 0.1)
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 508, maxHeight: .infinity)
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 1195, height: 675)
    .commands {
      CommandGroup(replacing: .newItem) {}
      CommandGroup(after: .appInfo) {
        Divider()
        Button("Quit completely") {
          AppDelegate.allowTermination = true
          NSApp.terminate(nil)
        }
        Button("Analyze captured activity now") {
          AnalysisManager.shared.analyzePendingActivity()
        }
        Button("Flow: Simulate Distraction") {
          FlowSessionMirror.shared.simulateDistraction()
        }
        .keyboardShortcut("D", modifiers: [.command, .shift])
        Button("Flow: Nudge Style — \(FlowNudgeVariant(rawValue: flowNudgeVariant)?.title ?? FlowNudgeVariant.side.title)") {
          let next = (FlowNudgeVariant(rawValue: flowNudgeVariant) ?? .side).next
          FlowNudgeVariant.current = next
          flowNudgeVariant = next.rawValue
        }
      }
    }
  }

  private var hasPendingNotificationNavigation: Bool {
    AppDelegate.pendingNotificationNavigationDestination != nil
  }

  private func dispatchPendingNotificationNavigation(after delay: TimeInterval) {
    guard hasPendingNotificationNavigation else { return }

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let destination = AppDelegate.pendingNotificationNavigationDestination else { return }
      AppDelegate.pendingNotificationNavigationDestination = nil

      switch destination {
      case .daily(let day) where day?.isEmpty == false:
        NotificationCenter.default.post(
          name: .navigateToDaily,
          object: nil,
          userInfo: ["day": day]
        )
      case .daily:
        NotificationCenter.default.post(name: .navigateToDaily, object: nil)
      case .support:
        NotificationCenter.default.post(name: .navigateToSupport, object: nil)
      case .weekly:
        NotificationCenter.default.post(name: .navigateToWeekly, object: nil)
      }
    }
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let navigateToDaily = Notification.Name("navigateToDaily")
  static let navigateToSupport = Notification.Name("navigateToSupport")
  static let navigateToWeekly = Notification.Name("navigateToWeekly")
  static let navigateToFlow = Notification.Name("navigateToFlow")
  static let timelineDataUpdated = Notification.Name("timelineDataUpdated")
  static let showTimelineFailureToast = Notification.Name("showTimelineFailureToast")
  static let showScreenRecordingPermissionNotice = Notification.Name(
    "showScreenRecordingPermissionNotice")
  static let openProvidersSettings = Notification.Name("openProvidersSettings")
  static let openAccountSettings = Notification.Name("openAccountSettings")
}

@MainActor
final class MainWindowController {
  static let shared = MainWindowController()

  private var openWindowAction: OpenWindowAction?
  private var hasPendingOpenRequest = false

  func register(_ openWindowAction: OpenWindowAction) {
    self.openWindowAction = openWindowAction

    if hasPendingOpenRequest {
      hasPendingOpenRequest = false
      openWindowAction(id: "main")
    }
  }

  func showMainWindow() {
    guard let openWindowAction else {
      hasPendingOpenRequest = true
      return
    }

    openWindowAction(id: "main")
  }
}

/// The window ground behind the main app: the kit's paper (one design, no palettes; C145).
private struct DayflowWindowBackground: View {
  var body: some View {
    TBDColor.paper.ignoresSafeArea()
  }
}

private struct MainWindowRegistrationView: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        MainWindowController.shared.register(openWindow)
      }
  }
}
