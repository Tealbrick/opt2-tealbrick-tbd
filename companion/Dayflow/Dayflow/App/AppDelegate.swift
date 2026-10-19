//
//  AppDelegate.swift
//  Dayflow
//

import TBDDesign
import TBDListening
import AppKit
import Combine
import ScreenCaptureKit
import ServiceManagement

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  enum PendingNotificationNavigationDestination: Equatable {
    case daily(day: String?)
    case weekly
    case support
  }

  // Legacy explicit-quit marker retained for existing callers.
  // Termination now delegates to Listening capture/save guards.
  static var allowTermination: Bool = false

  // Flag set when app is opened via notification tap - skips video intro
  static var pendingNotificationNavigationDestination: PendingNotificationNavigationDestination? =
    nil
  private var statusBar: StatusBarController!
  private var recorder: ScreenRecorder!
  private var terminationSignal: DispatchSourceSignal?
  private var powerObserver: NSObjectProtocol?
  private let screenshotShortcutTracker = ScreenshotShortcutTracker.shared
  private var deepLinkRouter: AppDeepLinkRouter?
  private var pendingDeepLinkURLs: [URL] = []

  override init() {
    UserDefaultsMigrator.migrateIfNeeded()
    super.init()
  }

  func applicationDidFinishLaunching(_ note: Notification) {
    // Route service/update termination through the same MP4 finalization as full Quit.
    signal(SIGTERM, SIG_IGN)
    let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    terminationSignal.setEventHandler {
      AppDelegate.allowTermination = true
      NSApp.terminate(nil)
    }
    self.terminationSignal = terminationSignal
    terminationSignal.resume()
    // Block termination by default; only specific flows enable it.
    AppDelegate.allowTermination = false
    applySavedDockIconPreference()
    TBDUpdater.shared.start()


    // Companion CLI writes (opt-in "Allow edits"). TBD never edits other apps' configs.
    AgentBridgeServer.shared.startIfEnabled()

    screenshotShortcutTracker.start()

    statusBar = StatusBarController()
    LaunchAtLoginManager.shared.bootstrapDefaultPreference()
    deepLinkRouter = AppDeepLinkRouter()

    // Check if we've passed the screen recording permission step
    let didOnboard = UserDefaults.standard.bool(forKey: "didOnboard")

    // Seed recording flag low, then create recorder so the first
    // transition to true will reliably start capture.
    AppState.shared.isRecording = false
    recorder = ScreenRecorder(autoStart: true)

    // Only attempt to start recording if we're past the screen step or fully onboarded.
    if didOnboard {
      // Onboarding complete - enable persistence and restore user preference
      AppState.shared.enablePersistence()

      // Try to start recording, but handle permission failures gracefully
      Task { [weak self] in
        guard let self else { return }
        guard ScreenRecordingPermissionNotice.isGranted else {
          await MainActor.run {
            AppState.shared.setRecording(
              false,
              analyticsReason: "auto",
              persistPreference: false
            )
          }
          if didOnboard {
            ScreenRecordingPermissionNotice.post(reason: "launch_preflight_missing")
          }
          self.flushPendingDeepLinks()
          return
        }

        do {
          // Check if we have permission by trying to access content
          _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
          // Permission granted - restore saved preference or default to ON
          await MainActor.run {
            let savedPref = AppState.shared.getSavedPreference()
            AppState.shared.setRecording(savedPref ?? true, analyticsReason: "auto")
          }
        } catch {
          // No permission or error - don't start recording
          // User will need to grant permission in onboarding
          await MainActor.run {
            AppState.shared.setRecording(
              false,
              analyticsReason: "auto",
              persistPreference: false
            )
          }
          if didOnboard {
            ScreenRecordingPermissionNotice.post(reason: "launch_shareable_content_failed")
          }
          print("Screen recording permission not granted, skipping auto-start")
        }
        self.flushPendingDeepLinks()
      }
    } else {
      // Still in early onboarding, don't enable persistence yet
      // Keep recording off and don't persist this state
      AppState.shared.isRecording = false
      flushPendingDeepLinks()
    }

    // Start the provider-routed analysis background job
    setupTimelineAnalysis()

    // Start inactivity monitoring for idle reset
    InactivityMonitor.shared.start()

    // Start Daily and Weekly notifications and retire legacy Journal reminders
    NotificationService.shared.start()

    // Start daily recap generation scheduler (checks every 5 minutes)
    DailyRecapScheduler.shared.start()


    powerObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willPowerOffNotification,
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        AppDelegate.allowTermination = true
      }
    }
  }

  /// Closing the main window must not quit TBD (C280 C14, "set and forget"): it keeps running in the menu bar so
  /// capture, Listen and Chat continue. SwiftUI otherwise terminates an app whose only scene is a `Window` when that
  /// window closes (checked on dev.6, 2026-10-19). Ported from the v1 branch claude/close-to-menubar.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  /// Dock icon click, or a second launch of the running app: bring the main window back.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { MainWindowController.shared.showMainWindow() }
    return true
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Cmd-Q means quit. Closing the window remains the background-use gesture.
    // Listening coordinates active meeting/voice-note completion before termination.
    return TBDListeningRuntime.shared.shouldTerminate(sender)
  }

  private func applySavedDockIconPreference() {
    let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
    NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
  }

  // Start timeline analysis as a background task
  private func setupTimelineAnalysis() {
    // Perform after a short delay to ensure other initialization completes
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
      AnalysisManager.shared.startAnalysisJob()
      print("AppDelegate: LLM analysis job started")
    }
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    if deepLinkRouter == nil {
      pendingDeepLinkURLs.append(contentsOf: urls)
      return
    }

    for url in urls {
      _ = deepLinkRouter?.handle(url)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    TBDChatRuntime.shared.stop()
    TBDListeningRuntime.shared.terminate()
    recorder?.finishForTermination()
    // Checkpoint WAL to persist any pending database changes before quit
    // Using .truncate to also reset the WAL file for a clean state
    StorageManager.shared.checkpoint(mode: .truncate)

    screenshotShortcutTracker.stop()

    if let observer = powerObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      powerObserver = nil
    }
    DailyRecapScheduler.shared.stop()
  }

  private func flushPendingDeepLinks() {
    guard let router = deepLinkRouter, !pendingDeepLinkURLs.isEmpty else { return }
    let urls = pendingDeepLinkURLs
    pendingDeepLinkURLs.removeAll()
    for url in urls {
      _ = router.handle(url)
    }
  }

}
