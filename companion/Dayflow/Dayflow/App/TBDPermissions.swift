import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import EventKit
import SwiftUI
import TBDDesign
import UserNotifications

/// TCC belongs to the signed host, never to a Portal account or workspace.
@MainActor
final class TBDPermissions: ObservableObject {
  static let shared = TBDPermissions()
  @Published private(set) var microphone = "Checking…"
  @Published private(set) var screen = "Checking…"
  @Published private(set) var accessibility = "Checking…"
  @Published private(set) var notifications = "Checking…"
  @Published private(set) var calendar = "Checking…"
  @Published private(set) var error = ""
  private var refreshing = false

  func refresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: microphone = "Allowed"
    case .notDetermined: microphone = "Not requested"
    case .denied: microphone = "Denied"
    case .restricted: microphone = "Restricted"
    @unknown default: microphone = "Unknown"
    }
    screen = CGPreflightScreenCaptureAccess() ? "Allowed" : "Not granted"
    accessibility = AXIsProcessTrusted() ? "Allowed" : "Not granted"
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral: notifications = "Allowed"
    case .notDetermined: notifications = "Not requested"
    case .denied: notifications = "Denied"
    @unknown default: notifications = "Unknown"
    }
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess, .authorized: calendar = "Allowed"
    case .writeOnly: calendar = "Write only"
    case .notDetermined: calendar = "Not requested"
    case .denied: calendar = "Denied"
    case .restricted: calendar = "Restricted"
    @unknown default: calendar = "Unknown"
    }
  }
  func request(_ permission: String) async {
    error = ""
    switch permission {
    case "Microphone":
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
      } else { open("Privacy_Microphone") }
    case "Screen recording":
      // Explicit user action only. macOS may require an app restart after approval.
      if screen == "Allowed" || !CGRequestScreenCaptureAccess() { open("Privacy_ScreenCapture") }
    case "Accessibility":
      _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
      open("Privacy_Accessibility")
    case "Notifications":
      if notifications == "Not requested" {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { self.error = error.localizedDescription }
      } else { open("Notifications") }
    case "Calendar": open("Privacy_Calendars")
    default: break
    }
    await refresh()
  }
  private func open(_ pane: String) {
    let address = pane == "Notifications" ? "x-apple.systempreferences:com.apple.Notifications-Settings.extension" : "x-apple.systempreferences:com.apple.preference.security?" + pane
    if let url = URL(string: address) { NSWorkspace.shared.open(url) }
  }
}

struct TBDPermissionsView: View {
  /// The remembered Always/Never choices for TBD's agent's local actions (design shots pass a seeded store).
  let localChoices: LocalChoicesStore?
  init(localChoices: LocalChoicesStore? = nil) { self.localChoices = localChoices }
  @ObservedObject private var permissions = TBDPermissions.shared
  @ObservedObject private var appState = AppState.shared

  @ObservedObject private var pauseManager = PauseManager.shared

  /// TBD-DEV7-1: permission granted but capture off (the state dev.7's setup left behind) must be visible and fixable
  /// here. Not during a pause the person chose (the menu bar shows and ends that).
  @ViewBuilder private var captureRow: some View {
    if permissions.screen == "Allowed" && !appState.isRecording && !pauseManager.isPaused {
      HStack(spacing: TBDKit.s3) {
        Text("Screen capture is off. Companion records nothing until you start it.")
          .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk)
        Spacer(minLength: TBDKit.s3)
        Button("Start capture") { RecordingControl.start(reason: "access_pane") }
          .buttonStyle(TBDButtonStyle(.primary))
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Access is granted to TBD on this Mac and shared across its features. Portal sign-in does not grant or revoke these permissions.")
        .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      row("Microphone", permissions.microphone, "Chat dictation, Listen and microphone meetings.")
      row("Screen recording", permissions.screen, "Companion screenshots and meetings that capture system audio. macOS lists this app as TBD; an older TBD in that list is a different app (the archived v1). After you allow it, quit TBD with Cmd-Q and open it again.")
      captureRow
      row("Accessibility", permissions.accessibility, "Global dictation insertion and desktop interactions.")
      row("Notifications", permissions.notifications, "Reminders, nudges and completion alerts.")
      row("Calendar", permissions.calendar, "Optional meeting calendar integration. Request access when enabling that feature.")
      Button("Refresh permissions") { Task { await permissions.refresh() } }
        .buttonStyle(TBDButtonStyle(.secondary))
      if !permissions.error.isEmpty { Text(permissions.error).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk) }
      SettingsLocalChoicesView(store: localChoices)
        .padding(.top, TBDKit.s3)
    }
    .task {
      while !Task.isCancelled {
        await permissions.refresh()
        do { try await Task.sleep(for: .seconds(3)) } catch { return }
      }
    }
  }
  private func row(_ name: String, _ status: String, _ detail: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(name).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
        Spacer()
        Text(status).font(TBDTokens.Typography.tag).foregroundStyle(status == "Allowed" ? TBDColor.tealInk : TBDColor.muted)
        Button(status == "Allowed" || name == "Calendar" ? "Manage" : "Allow…") {
          Task { await permissions.request(name) }
        }
        .buttonStyle(TBDButtonStyle(.secondary))
      }
      Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
    }
  }
}
