import SwiftUI
import CoreGraphics
import AppKit
import TBDDesign

/// Minimal local setup. No vendor intro or account requirement. Capture starts when Screen Recording is granted
/// (TBD-DEV7-1); WP-ONB (C285) replaces this screen.
struct TBDCompanionSetup: View {
  @AppStorage("didOnboard") private var completed = false
  @State private var screenAccess = CGPreflightScreenCaptureAccess()
  @State private var step = 0

  var body: some View {
    VStack(alignment: .leading, spacing: TBDKit.s5) {
      Text("Companion setup").font(TBDTokens.Typography.title).foregroundStyle(TBDColor.ink)
      TBDStepFlow(steps: steps, current: $step, size: CGSize(width: 600, height: 380)) { openCompanion() }
        .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
        .clipShape(TBDBrickShape())
    }
    .padding(TBDKit.s10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      screenAccess = CGPreflightScreenCaptureAccess()
    }
  }

  /// Step 1 shows the screen-access state live (optional: capture stays paused, access can be granted later); step 2 opens the app.
  private var steps: [TBDStep] {
    [
      TBDStep("Screen access", optional: true, skipLabel: "Skip, allow it later") {
        VStack(alignment: .leading, spacing: TBDKit.s5) {
          Text("Your screen-activity timeline and Daily recap. Capture starts as soon as macOS allows screen recording.")
            .font(TBDTokens.Typography.body)
            .foregroundStyle(TBDColor.muted)
          HStack {
            Label(screenAccess ? "Screen access granted" : "Screen access not granted", systemImage: screenAccess ? "checkmark.circle" : "display")
              .font(TBDTokens.Typography.control)
              .foregroundStyle(screenAccess ? TBDColor.tealInk : TBDColor.ink)
            Spacer()
            if !screenAccess {
              Button("Screen recording settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
              }
              .buttonStyle(TBDButtonStyle(.secondary))
            }
          }
        }
      },
      TBDStep("Open", nextLabel: "Open Companion") {
        Text("Configure the analysis model in Companion Settings. Manage the shared Portal account and macOS permissions in Settings.")
          .font(TBDTokens.Typography.body)
          .foregroundStyle(TBDColor.muted)
      },
    ]
  }

  /// Ends setup. Capture is ON when Screen Recording is granted ("set and forget", C280 C14, TBD-DEV7-1); without the
  /// grant it stays off WITHOUT saving "off", so it starts by itself at the next launch once macOS has the grant.
  private func openCompanion() {
    AppState.shared.enablePersistence()
    Self.finishSetup(
      screenRecordingGranted: ScreenRecordingPermissionNotice.isGranted,
      setRecording: { on, persist in AppState.shared.setRecording(on, persistPreference: persist) },
      postNotice: { ScreenRecordingPermissionNotice.post(reason: "setup_without_screen_recording") })
    completed = true
  }

  /// The setup's last step, as a rule (tested): granted → capture on and saved; not granted → off, NOT saved, notice.
  static func finishSetup(
    screenRecordingGranted: Bool, setRecording: (_ on: Bool, _ persist: Bool) -> Void, postNotice: () -> Void
  ) {
    if screenRecordingGranted {
      setRecording(true, true)
    } else {
      setRecording(false, false)
      postNotice()
    }
  }
}
