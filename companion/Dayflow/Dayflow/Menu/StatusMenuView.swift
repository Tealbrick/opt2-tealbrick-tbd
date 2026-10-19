import AppKit
import SwiftUI
import TBDDesign
import TBDListening
import TBDModels

@MainActor
struct StatusMenuView: View {
  let dismissMenu: () -> Void
  @ObservedObject private var appState = AppState.shared
  @ObservedObject private var pauseManager = PauseManager.shared
  @ObservedObject private var listening = TBDListeningRuntime.shared

  private var controlMode: RecordingControlMode {
    RecordingControl.currentMode(appState: appState, pauseManager: pauseManager)
  }

  var body: some View {
    ScrollView {
    VStack(spacing: 6) {
      // Pause/Resume section
      if controlMode == .active {
        PauseSection(onPause: pauseRecording)
      } else {
        PausedSection(onResume: resumeRecording)
      }

      MenuDivider()

      MenuRow(
        title: String(localized: "Open Tealbrick"), assetImage: "TealbrickLogo", action: openDayflow)
      MenuRow(title: String(localized: "Open Recordings"), action: openRecordingsFolder)
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        Text("Meeting: " + listening.meetingStatus).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      }
      MenuRow(title: "Dictate", systemImage: "mic", action: { audioAction(.dictation) })
      MenuRow(title: listening.voiceNoteRecording ? "Finish voice note" : "Record voice note", systemImage: "waveform", action: {
        Task { await listening.toggleVoiceNote() }
      }).disabled(listening.captureBusy)
      MenuRow(title: "Start / stop meeting", systemImage: "record.circle", action: { audioAction(.meeting) })
      MenuRow(title: "Meeting controls", systemImage: "slider.horizontal.3", action: { audioAction(.meetingPanel) })
      MenuRow(title: "Transcribe file", systemImage: "doc", action: { audioAction(.transcribeFile) })
      MenuRow(title: "Transcribe URL", systemImage: "link", action: { audioAction(.transcribeURL) })
      MenuRow(title: "Recover voice-note audio", systemImage: "folder", action: {
        performAfterMenuDismiss {
          let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(TBDIdentity.dataFolder + "/Listening/VoiceNotes")
          if FileManager.default.fileExists(atPath: root.path) { NSWorkspace.shared.open(root) }
        }
      })
      MenuRow(title: "Recent dictations", systemImage: "clock", action: { audioAction(.history) })
      if !listening.lastRawTranscript.isEmpty {
        MenuRow(title: "Copy last raw transcript", systemImage: "doc.on.doc", action: {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(listening.lastRawTranscript, forType: .string)
        })
      }
      if !listening.captureMessage.isEmpty { Text(listening.captureMessage).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted) }
      MenuRow(title: "Models", systemImage: "cpu", action: { openSettings("engine") })
      MenuRow(title: "Settings", systemImage: "gearshape", action: { openSettings("other") })
      MenuRow(title: "About / Support", systemImage: "questionmark.circle", action: { openSettings("about") })

      MenuDivider()

      MenuRow(
        title: String(localized: "Quit TBD"), systemImage: "power", accent: TBDColor.brickInk,
        action: quitDayflow)
    }
    }
    .scrollIndicators(.hidden)
    .frame(maxHeight: 620)
    .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightBody))
    .foregroundStyle(TBDColor.ink)
    .padding(.vertical, 9)
    .padding(.horizontal, 9)
    .frame(minWidth: 280, maxWidth: 300)
    // Brick floating menu: tile, hair ring and the one float shadow.
    .tbdFloating()
  }

  private func pauseRecording(duration: PauseDuration) {
    pauseManager.pause(for: duration, source: .menuBar)
  }

  private func resumeRecording() {
    if pauseManager.isPaused {
      pauseManager.resume(source: .userClickedMenuBar)
    } else {
      RecordingControl.start(reason: "user_menu_bar")
    }
  }

  private func openDayflow() {
    performAfterMenuDismiss {
      let showDockIcon = UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true
      if showDockIcon {
        NSApp.setActivationPolicy(.regular)
      }

      NSApp.unhide(nil)
      MainWindowController.shared.showMainWindow()
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func openRecordingsFolder() {
    performAfterMenuDismiss {
      let directory = StorageManager.shared.recordingsRoot
      NSWorkspace.shared.open(directory)
    }
  }

  private func audioAction(_ action: TBDListeningAction) {
    performAfterMenuDismiss { listening.menuAction(action) }
  }
  private func openSettings(_ section: String) {
    openDayflow()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      NotificationCenter.default.post(name: Notification.Name("tbdOpenSettings"), object: section)
    }
  }

  private func quitDayflow() {
    performAfterMenuDismiss {
      AppDelegate.allowTermination = true
      NSApp.terminate(nil)
    }
  }

  private func performAfterMenuDismiss(_ action: @escaping () -> Void) {
    dismissMenu()

    DispatchQueue.main.async {
      DispatchQueue.main.async {
        action()
      }
    }
  }
}

// MARK: - Pause Section (Not Paused State)

private struct PauseSection: View {
  let onPause: (PauseDuration) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Header
      Text("Screen capture")
        .font(TBDTokens.Typography.label)
        .foregroundStyle(TBDColor.muted)
        .padding(.horizontal, 5)

      // Duration picker
      DurationPicker(onSelect: onPause)
    }
  }
}

// MARK: - Duration Picker

private struct DurationPicker: View {
  let onSelect: (PauseDuration) -> Void

  private let options: [(label: String, duration: PauseDuration)] = [
    (String(localized: "15 Mins"), .minutes15),
    (String(localized: "30 Mins"), .minutes30),
    (String(localized: "1 Hour"), .hour1),
    ("∞", .indefinite),
  ]

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { index, option in
        DurationOption(
          label: option.label,
          isFirst: index == 0,
          isLast: index == options.count - 1,
          onTap: { onSelect(option.duration) }
        )

        if index < options.count - 1 {
          Rectangle()
            .fill(TBDColor.line)
            .frame(width: TBDKit.hair, height: 16)
        }
      }
    }
    .background(TBDColor.plate, in: TBDBrickShape())
    .overlay(TBDBrickShape().strokeBorder(TBDColor.line, lineWidth: TBDKit.hair))
  }
}

private struct DurationOption: View {
  let label: String
  let isFirst: Bool
  let isLast: Bool
  let onTap: () -> Void

  @State private var isHovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onTap) {
      Text(label)
        .font(TBDTokens.Typography.label)
        .foregroundStyle(isHovering ? TBDColor.primaryOn : TBDColor.ink)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
          Group {
            if isHovering {
              TBDBrickShape().fill(TBDColor.primaryFill)
            }
          }
        )
        .contentShape(TBDBrickShape())
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering in
      withAnimation(TBDMotion.animation(TBDMotion.instant, reduce: reduceMotion)) {
        isHovering = hovering
      }
    }
  }
}

// MARK: - Paused Section (Active Pause State)

private struct PausedSection: View {
  let onResume: () -> Void
  @ObservedObject private var pauseManager = PauseManager.shared

  var body: some View {
    VStack(spacing: 6) {
      // Countdown badge (only shown for timed pause)
      if let timeString = pauseManager.remainingTimeFormatted {
        CountdownBadge(remainingTime: timeString)
      }

      // Resume button
      MenuRow(
        title: String(localized: "Resume Tealbrick"),
        systemImage: "play.circle",
        accent: TBDColor.tealInk,
        action: onResume
      )
    }
  }
}

// MARK: - Countdown Badge

private struct CountdownBadge: View {
  let remainingTime: String

  var body: some View {
    TBDNotice("Tealbrick paused for \(remainingTime)", tone: .needsYou)
  }
}

// MARK: - Menu Row

private struct MenuRow: View {
  let title: String
  var systemImage: String? = nil
  var assetImage: String? = nil
  var accent: Color = TBDColor.ink
  var keepsMenuOpen: Bool = false
  var action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button(action: handleTap) {
      HStack(spacing: 7) {
        if let systemImage {
          Image(systemName: systemImage)
            .font(TBDFonts.symbol(TBDKit.textHint))
            .foregroundStyle(accent)
            .frame(width: 17)
        } else if let assetImage {
          Image(assetImage)
            .resizable()
            .scaledToFit()
            .frame(width: 16, height: 16)
            .frame(width: 17)
        } else {
          // Empty spacer to align text with rows that have icons
          Color.clear.frame(width: 17)
        }

        Text(title)
          .font(TBDTokens.Typography.control)
          .foregroundStyle(TBDColor.ink)
          .lineLimit(1)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 5)
      .frame(minHeight: 32)
      .contentShape(TBDBrickShape())
      // Brick hover: plate fill, never a pill.
      .background(TBDBrickShape().fill(hovering ? TBDColor.plate : Color.clear))
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
    .onHover { hovering = $0 }
  }

  private func handleTap() {
    action()
  }
}

// MARK: - Menu Divider

private struct MenuDivider: View {
  var body: some View {
    Rectangle()
      .fill(TBDColor.line)
      .frame(height: TBDKit.hair)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
  }
}
