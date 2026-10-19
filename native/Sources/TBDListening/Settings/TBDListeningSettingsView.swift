import AppKit
import SwiftUI
import TBDDesign
import TBDModels
import TBDSpeech

/// The Listening settings sections the host can open. The host (Companion Settings) sends the raw value.
/// "capture" is the v1 Capture tab: the microphone plus a Dictation | Meetings workflow switcher.
public enum TBDListeningSettingsSection: String, CaseIterable, Sendable {
    case capture, engine, ai, dictation, meetings, system

    /// Resolves what the host sends. Unknown names fall back to Capture, never to an empty page.
    public static func resolve(_ name: String) -> TBDListeningSettingsSection {
        TBDListeningSettingsSection(rawValue: name) ?? .capture
    }
}

/// The workflow shown inside Capture (v1 `SettingsCaptureWorkflow`: Dictation, Transcription, Meetings).
public enum TBDCaptureWorkflow: String, CaseIterable, Identifiable, Sendable {
    case dictation, transcription, meetings
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dictation: "Dictation"
        case .transcription: "Transcription"
        case .meetings: "Meetings"
        }
    }
    /// Remembered across launches, as in v1.
    public static let defaultsKey = "tbd.listening.settingsCaptureWorkflow"
    public static func stored(_ defaults: UserDefaults = .standard) -> TBDCaptureWorkflow {
        defaults.string(forKey: defaultsKey).flatMap(TBDCaptureWorkflow.init(rawValue:)) ?? .dictation
    }
}

/// Settings for one section (see `TBDListeningSettingsSection`).
struct TBDListeningSettingsView: View {
    let section: String
    let context: TBDListeningContext

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch TBDListeningSettingsSection.resolve(section) {
                case .capture: TBDCaptureSettings(context: context)
                case .engine: TBDEngineSettings(context: context)
                case .ai: TBDAISettings(); TBDKnowledgeSettings()
                case .dictation: TBDDictationSettings(context: context)
                case .meetings: TBDMeetingSettings(context: context)
                case .system: TBDSystemSettings(context: context)
                }
            }
            .font(TBDTokens.Typography.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, TBDTokens.Space.lg)   // the host's pane header sits above (TBD-UX-01)
        }
    }
}

/// v1 Capture tab: microphone first, then the workflow switcher and that workflow's settings.
struct TBDCaptureSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var workflow = TBDCaptureWorkflow.stored()
    @State private var devices: [TBDAudioDevices.Input] = []
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDSettingsRow("Microphone", help: "System Default follows the input chosen in macOS Sound settings.") {
                TBDSelect(selection: tbdBinding({ prefs.microphoneUID ?? "" }, { uid in
                    prefs.microphoneUID = uid.isEmpty ? nil : uid
                    env.microphone.setPreferredDevice(uid: prefs.microphoneUID)
                }, refresh: { tick += 1 }), options: [("", "System Default")] + devices.map { ($0.uid, $0.name) })
                    .frame(width: 240)
            }
            .id(tick)
            TBDLabel("Capture workflow").padding(.top, TBDTokens.Space.lg).padding(.bottom, TBDTokens.Space.xs)
            TBDSegmented(selection: $workflow, options: TBDCaptureWorkflow.allCases.map { ($0, $0.title) })
                .padding(.bottom, TBDTokens.Space.sm)
            .onChange(of: workflow) { _, value in UserDefaults.standard.set(value.rawValue, forKey: TBDCaptureWorkflow.defaultsKey) }
            switch workflow {
            case .dictation: TBDDictationSettings(context: context)
            case .transcription:
                TBDTranscriptionHotkeySettings(context: context)
                TBDTranscriptionSettings()
            case .meetings: TBDMeetingSettings(context: context)
            }
        }
        .onAppear { devices = TBDAudioDevices.inputs() }
    }
}

/// Bool binding over a preferences property.
@MainActor
func tbdBinding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void, refresh: @escaping () -> Void = {}) -> Binding<T> {
    nonisolated(unsafe) let read = get
    nonisolated(unsafe) let write = set
    nonisolated(unsafe) let after = refresh
    return Binding(get: { read() }, set: { write($0); after() })
}

// MARK: - Engine

@MainActor
final class TBDModelsModel: ObservableObject {
    @Published var statuses: [TBDModelManager.Status] = []
    @Published var progress: [TBDModelManager.Model: Double] = [:]
    @Published var error: String?
    /// Reads the Nemotron language preference, which picks that model's variant.
    var manager: TBDModelManager { TBDModelManager(preferences: TBDListeningPreferences()) }

    func refresh() { statuses = manager.status() }

    func isDownloaded(_ engine: TBDSpeechEngineKind) -> Bool { manager.isDownloaded(engine: engine) }

    /// Downloads only here, on the person's click.
    func download(_ model: TBDModelManager.Model) {
        guard progress[model] == nil else { return }
        progress[model] = 0
        error = nil
        let manager = self.manager
        Task {
            do {
                try await manager.download(model) { value in Task { @MainActor in if self.progress[model] != nil { self.progress[model] = value } } }
            } catch { self.error = "\(model.title): \(error.localizedDescription)" }
            progress[model] = nil
            refresh()
        }
    }

    func delete(_ model: TBDModelManager.Model, inUse: Bool) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.title)?"
        alert.informativeText = inUse ? "This is a selected engine. Listen cannot use it until you download it again or choose another engine." : "You can download it again later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try manager.delete(model) } catch { self.error = error.localizedDescription }
        refresh()
    }
}

/// Capability chips for one engine.
struct TBDEngineCapabilityChips: View {
    let kind: TBDSpeechEngineKind
    var body: some View {
        let capabilities = kind.capabilities
        HStack(spacing: TBDTokens.Space.xs) {
            TBDChip(languageText(capabilities), color: TBDColor.muted)
            TBDChip(capabilities.wordTimestamps ? "Timestamps" : "Plain text", color: capabilities.wordTimestamps ? TBDColor.teal : TBDColor.brick)
            if capabilities.streaming { TBDChip("Streaming") } else if capabilities.tailPreview { TBDChip("Live preview") }
            if capabilities.diarizationCompatible { TBDChip("Speakers") }
            if !capabilities.satisfiesMemory() { TBDChip("Needs 16 GB", color: TBDColor.brick) }
        }
    }

    private func languageText(_ capabilities: TBDEngineCapabilities) -> String {
        switch capabilities.languageMode {
        case .fixed: "English"
        case .automatic: "\(capabilities.languages?.count ?? 0) languages"
        case .selectable: capabilities.languages.map { "\($0.count) languages" } ?? "Many languages"
        }
    }
}

struct TBDEngineSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @StateObject private var models = TBDModelsModel()
    @State private var tick = 0

    private static let followLive = "follow-live"

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            Text("Choose one engine for live text (dictation and the meeting live transcript) and one for final transcripts (files, links, podcasts and the meeting transcript after you stop). Up to two models stay loaded.")
                .foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, TBDTokens.Space.md)
            TBDSettingsRow("Live engine", help: "Dictation and meeting live transcript. Streaming engines show text while you speak.") {
                VStack(alignment: .trailing, spacing: TBDTokens.Space.xs) {
                    TBDSelect(selection: tbdBinding({ prefs.liveEngine }, { prefs.liveEngine = $0 }, refresh: changed),
                              options: TBDSpeechEngineKind.allCases.map { ($0, label($0)) })
                        .frame(width: 260)
                    TBDEngineCapabilityChips(kind: prefs.liveEngine)
                }
            }
            TBDSettingsRow("Final engine", help: "Files, links, podcasts and meeting transcripts. Pick an accurate engine here; speed matters less.") {
                VStack(alignment: .trailing, spacing: TBDTokens.Space.xs) {
                    Picker("", selection: tbdBinding({ prefs.finalEngineOverride?.rawValue ?? Self.followLive },
                                                     { prefs.finalEngineOverride = TBDSpeechEngineKind(rawValue: $0) }, refresh: changed)) {
                        Text("Same as live engine").tag(Self.followLive)
                        Divider()
                        ForEach(TBDSpeechEngineKind.allCases) { Text(label($0)).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 260)
                    TBDEngineCapabilityChips(kind: prefs.finalEngine)
                }
            }
            if !prefs.finalEngine.capabilities.wordTimestamps {
                Text("\(prefs.finalEngine.displayName) returns plain text: no subtitles (SRT, VTT), no speaker labels and no word timing for final transcripts.")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.brickInk).fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, TBDTokens.Space.xs)
            }
            ForEach(languageEngines(prefs)) { kind in languageRow(kind, prefs: prefs) }
            TBDSettingsRow("Show text while dictating", help: prefs.liveEngine.capabilities.livePreview
                           ? "Live preview in the dictation pill. The pasted text still comes from the full recording."
                           : "\(prefs.liveEngine.displayName) has no live preview. Choose Parakeet or a streaming engine.") {
                Toggle("", isOn: tbdBinding({ prefs.dictationLivePreview }, { prefs.dictationLivePreview = $0 }, refresh: changed))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize().disabled(!prefs.liveEngine.capabilities.livePreview)
            }
            TBDSettingsRow("Meeting live transcript", help: prefs.liveEngine.capabilities.meetingLivePreview
                           ? "Transcribe meetings while recording, cut at pauses (voice activity model) when it is downloaded."
                           : "\(prefs.liveEngine.displayName) has no timestamps, so meetings show no live transcript.") {
                Toggle("", isOn: tbdBinding({ prefs.meetingLivePreview }, { prefs.meetingLivePreview = $0 }, refresh: changed))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize().disabled(!prefs.liveEngine.capabilities.meetingLivePreview)
            }
            TBDLinkDownloadSettings(preferences: prefs)
            TBDSettingsRow("Speaker detection", help: "Label speakers in meetings and files (needs the speaker model and an engine with timestamps).") {
                Toggle("", isOn: tbdBinding({ prefs.diarize }, { prefs.diarize = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDLabel("Models").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(models.statuses) { status in modelRow(status, prefs: prefs) }
            if let error = models.error { TBDNotice(error, tone: .needsYou).padding(.top, TBDTokens.Space.sm) }
            Text("Models download only when you click Download (from Hugging Face). Podcast links and searches use the Apple Podcasts directory (itunes.apple.com) and the show's RSS feed to find the episode audio. Video links use yt-dlp (downloaded once from github.com/yt-dlp and checked weekly), which contacts the linked site. Nothing else leaves this Mac. Models are stored in \(TBDListeningPaths.models.path) · \(models.manager.totalBytes.tbdByteString) used.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.top, TBDTokens.Space.md).textSelection(.enabled)
        }
        .id(tick)
        .onAppear { models.refresh() }
    }

    private func changed() {
        tick += 1
        models.refresh()
        Task { await env.speech.warmUp() }
    }

    private func label(_ kind: TBDSpeechEngineKind) -> String {
        kind.displayName + (models.isDownloaded(kind) ? "" : " (not downloaded)")
    }

    /// Selected engines that take a language choice.
    private func languageEngines(_ prefs: TBDListeningPreferences) -> [TBDSpeechEngineKind] {
        var kinds: [TBDSpeechEngineKind] = []
        for kind in [prefs.liveEngine, prefs.finalEngine] where kind.capabilities.languageMode == .selectable && !kinds.contains(kind) {
            kinds.append(kind)
        }
        return kinds
    }

    @ViewBuilder
    private func languageRow(_ kind: TBDSpeechEngineKind, prefs: TBDListeningPreferences) -> some View {
        let capabilities = kind.capabilities
        let help = kind == .cohere ? "Cohere cannot detect the language; it transcribes in the one you choose."
            : kind == .nemotronMultilingual ? "A language hint loads a smaller, faster model for English, Spanish, French, Italian, Portuguese and German (a separate download)."
            : "ISO code such as en, de, ko. Leave empty to detect automatically."
        TBDSettingsRow("\(capabilities.displayName) language", help: help) {
            if let languages = capabilities.languages {
                TBDSelect(selection: tbdBinding({ prefs.language(for: kind) ?? capabilities.defaultLanguage ?? "" },
                                                { prefs.setLanguage($0, for: kind) }, refresh: changed),
                          options: languages.map { code in
                              (code, Locale.current.localizedString(forLanguageCode: code).map { "\($0) (\(code))" } ?? code)
                          })
                    .frame(width: 200)
            } else {
                TextField("auto", text: tbdBinding({ prefs.language(for: kind) ?? "" }, { prefs.setLanguage($0, for: kind) }, refresh: { models.refresh() }))
                    .tbdField().frame(width: 80)
            }
        }
    }

    private func modelRow(_ status: TBDModelManager.Status, prefs: TBDListeningPreferences) -> some View {
        let model = status.model
        let roles = [model.engine == prefs.liveEngine ? "live" : nil, model.engine == prefs.finalEngine ? "final" : nil].compactMap { $0 }
        let inUse = !roles.isEmpty
        let title = model.title + (roles.isEmpty ? "" : " · " + roles.joined(separator: " and "))
        return TBDSettingsRow(title, help: model.detail) {
            HStack(spacing: TBDTokens.Space.sm) {
                if let value = models.progress[model] {
                    ProgressView(value: value).frame(width: 120)
                } else if status.downloaded {
                    Text(status.bytes.tbdByteString).foregroundStyle(TBDTokens.muted)
                    Button("Delete") { models.delete(model, inUse: inUse) }.buttonStyle(TBDButtonStyle(.quiet))
                } else {
                    Button("Download") { models.download(model) }.buttonStyle(TBDButtonStyle(inUse ? .primary : .secondary))
                }
            }
        }
    }
}

// MARK: - AI

struct TBDAISettings: View {
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            Text("Listen uses your model routes: “cleanup” for transcript cleanup, “analysis” for summaries and questions, “general” for transforms. Assign them in Settings → Models. Raw transcripts are always kept.")
                .foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, TBDTokens.Space.md)
            TBDSettingsRow("Clean up hotkey dictation", help: "Send dictated text to the cleanup model before pasting.") {
                Toggle("", isOn: tbdBinding({ prefs.dictationCleanup }, { prefs.dictationCleanup = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Clean up chat dictation") {
                Toggle("", isOn: tbdBinding({ UserDefaults.standard.bool(forKey: TBDCleanupPolicy.chatKey) },
                                            { UserDefaults.standard.set($0, forKey: TBDCleanupPolicy.chatKey) }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Clean up voice notes") {
                Toggle("", isOn: tbdBinding({ UserDefaults.standard.bool(forKey: TBDCleanupPolicy.voiceNoteKey) },
                                            { UserDefaults.standard.set($0, forKey: TBDCleanupPolicy.voiceNoteKey) }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            promptEditor("Cleanup prompt", text: tbdBinding({ prefs.cleanupPrompt }, { prefs.cleanupPrompt = $0 }),
                         reset: { prefs.cleanupPrompt = TBDListeningPreferences.defaultCleanupPrompt; tick += 1 })
            // Summary prompts and Transforms moved to their own Listening pages (prompt library with versions).
            Text("Summary prompts live on the Listen Prompts page; text Transforms and their hotkeys live on the Transforms page.")
                .foregroundStyle(TBDTokens.muted).fixedSize(horizontal: false, vertical: true).padding(.top, TBDTokens.Space.xl)
        }
        .id(tick)
    }

    private func promptEditor(_ title: String, text: Binding<String>, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: TBDTokens.Space.xs) {
            HStack { TBDLabel(title); Spacer(); Button("Reset", action: reset).buttonStyle(TBDButtonStyle(.quiet)) }
            TextEditor(text: text).font(TBDTokens.Typography.body).foregroundStyle(TBDColor.fieldOn).frame(height: 70).scrollContentBackground(.hidden)
                .padding(6).background(TBDColor.fieldFill, in: TBDBrickShape())
                .overlay(TBDBrickShape().strokeBorder(TBDColor.fieldEdge, lineWidth: TBDKit.hair))
        }
        .padding(.top, TBDTokens.Space.lg)
    }
}

// MARK: - Meetings

struct TBDMeetingSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            TBDHotkeyRow(title: "Meeting hotkey", help: "Global shortcut that immediately starts or stops meeting recording.",
                         surface: .meeting, context: context) { tick += 1 }
            TBDSettingsRow("Meeting reminders", help: "A minute before a calendar meeting, offer to record it. Uses your calendars on this Mac.") {
                Toggle("", isOn: tbdBinding({ prefs.calendarReminders }, { prefs.calendarReminders = $0 },
                                            refresh: { tick += 1; context.meetings.configureCalendar() })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Start recording automatically", help: "Record calendar meetings when they begin. Off by default; tell participants you record.") {
                Toggle("", isOn: tbdBinding({ prefs.calendarAutoStart }, { prefs.calendarAutoStart = $0 },
                                            refresh: { tick += 1; context.meetings.configureCalendar() })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Summarise each meeting", help: "When a meeting transcript is saved, summarise it with the summary prompt. Needs a model on the Analysis route.") {
                Toggle("", isOn: tbdBinding({ prefs.autoSummarizeMeetings }, { prefs.autoSummarizeMeetings = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Auto-title meetings", help: "When a meeting transcript is saved, name it from what was said. Only replaces the automatic \"Meeting <date>\" title, never one you set. Needs a model on the Analysis route.") {
                Toggle("", isOn: tbdBinding({ prefs.autoGenerateMeetingTitles }, { prefs.autoGenerateMeetingTitles = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Show floating meeting controls", help: "Shows the small recording pill while a meeting is active. Turn this off to control recording from the menu bar, hotkey, or Meetings tab.") {
                Toggle("", isOn: tbdBinding({ prefs.showMeetingRecordingPill }, { prefs.showMeetingRecordingPill = $0 },
                                            refresh: { tick += 1; context.meetings.refreshPill() })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Open app when meeting ends", help: "Brings TBD forward showing the transcript when a recording finishes. Turn this off to keep working. The meeting saves to your library in the background.") {
                Toggle("", isOn: tbdBinding({ prefs.openAppAfterMeetingEnd }, { prefs.openAppAfterMeetingEnd = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDSettingsRow("Notify when transcript is ready", help: "Plays a chime and shows a notification when a meeting finishes transcribing in the background. Applies when the app isn't set to open automatically.") {
                Toggle("", isOn: tbdBinding({ prefs.notifyOnMeetingEnd }, { prefs.notifyOnMeetingEnd = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize().disabled(prefs.openAppAfterMeetingEnd)
            }
            TBDSettingsRow("Audio sources", help: prefs.meetingAudioSourceMode.detail) {
                TBDSelect(selection: tbdBinding({ prefs.meetingAudioSourceMode }, { prefs.meetingAudioSourceMode = $0 }, refresh: { tick += 1 }),
                          options: TBDMeetingAudioSource.allCases.map { ($0, $0.title) })
                    .frame(width: 260)
            }
            TBDSettingsRow("Start meetings muted", help: "Begin recording with your microphone off. Unmute from the meeting panel when you want to speak. System-audio-only capture ignores this. Changes apply to your next recording.") {
                Toggle("", isOn: tbdBinding({ prefs.startMeetingsMuted }, { prefs.startMeetingsMuted = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize().disabled(!prefs.meetingAudioSourceMode.capturesMicrophone)
            }
            TBDSettingsRow("Stop recording automatically", help: "Stop after a meeting app quits, or both channels stay quiet for a few minutes. A countdown lets you keep recording first.") {
                Toggle("", isOn: tbdBinding({ prefs.meetingAutoStopEnabled }, { prefs.meetingAutoStopEnabled = $0 }, refresh: { tick += 1 }))
                    .labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDAutoSaveSettings(scope: .meeting)
            TBDSettingsRow("Other participants", help: "Recording system audio needs Screen & System Audio Recording permission for TBD. Without it, only your microphone is recorded.") {
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(TBDButtonStyle(.secondary))
            }
        }
        .id(tick)
    }
}

// MARK: - System

struct TBDSystemSettings: View {
    let context: TBDListeningContext
    @EnvironmentObject private var env: TBDListeningEnvironment
    @State private var tick = 0
    @State private var usage: [(String, Int64)] = []

    var body: some View {
        let prefs = env.preferences
        VStack(alignment: .leading, spacing: 0) {
            // The microphone is chosen in one place: Capture (TBD-UX-01).
            TBDSettingsRow("Microphone", help: "Choose the microphone in Capture.") {
                Button("Open Capture") {
                    NotificationCenter.default.post(name: Notification.Name("tbdListeningSettingsTabChanged"), object: "capture")
                }
                .buttonStyle(TBDButtonStyle(.secondary))
            }
            TBDSettingsRow("Save dictation history", help: "Voice notes are always saved.") {
                Toggle("", isOn: tbdBinding({ prefs.keepHistory }, { prefs.keepHistory = $0 }, refresh: { tick += 1 })).labelsHidden().toggleStyle(TBDSwitchStyle()).fixedSize()
            }
            TBDRetentionSettingsView(retention: context.retention)
            TBDLabel("Storage").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(usage, id: \.0) { name, bytes in
                HStack { Text(name); Spacer(); Text(bytes.tbdByteString).foregroundStyle(TBDTokens.muted) }.padding(.vertical, 3)
            }
            HStack(spacing: TBDTokens.Space.sm) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([TBDListeningPaths.root]) }
                    .buttonStyle(TBDButtonStyle(.secondary))
                Spacer()
                Button("Delete all Listen data…", role: .destructive) { context.retention.deleteAll(context: context); refreshUsage() }
                    .buttonStyle(TBDButtonStyle(.destructive))
            }
            .padding(.top, TBDTokens.Space.md)
        }
        .id(tick)
        .onAppear { refreshUsage() }
    }

    private func refreshUsage() {
        usage = [("Models", TBDListeningPaths.models), ("Meetings", TBDListeningPaths.meetings), ("Dictations", TBDListeningPaths.dictations),
                 ("Voice notes", TBDListeningPaths.voiceNotes), ("Downloads", TBDListeningPaths.downloads), ("Library database", TBDListeningPaths.database)]
            .map { ($0.0, TBDListeningPaths.diskUsage(of: $0.1)) }
    }
}

/// Per-kind retention: keep forever, delete after N days, or drop audio after transcription.
struct TBDRetentionSettingsView: View {
    @ObservedObject var retention: TBDRetentionController
    @EnvironmentObject private var env: TBDListeningEnvironment

    var body: some View {
        let settings = env.preferences.retention
        VStack(alignment: .leading, spacing: 0) {
            TBDLabel("Retention").padding(.top, TBDTokens.Space.xl).padding(.bottom, TBDTokens.Space.xs)
            ForEach(TBDRetentionKind.allCases) { kind in
                let policy = settings[kind]
                TBDSettingsRow(kind.title, help: kind.help) {
                    HStack(spacing: TBDTokens.Space.sm) {
                        TBDSelect(selection: Binding(get: { policy.mode }, set: { mode in
                            retention.set(TBDRetentionPolicy(mode: mode, days: policy.days), for: kind)
                        }), options: kind.modes.map { ($0, $0.title(for: kind)) })
                            .frame(width: 240)
                        if policy.mode == .deleteAfterDays {
                            TBDRetentionDays(days: policy.days) { retention.set(TBDRetentionPolicy(mode: .deleteAfterDays, days: $0), for: kind) }
                        }
                    }
                }
            }
            Text("Only “Delete after” removes existing items; it runs at launch and daily. Your original files are never removed.")
                .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).padding(.top, TBDTokens.Space.xs)
            if let result = retention.lastResult, result.changed {
                Text("Last cleanup removed \(result.deletedDictations + result.deletedTranscriptions) item(s) and audio from \(result.detachedAudio) meeting(s).")
                    .font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
            }
        }
    }
}

/// Day count editor, 1–365, committed on submit or stepper change.
struct TBDRetentionDays: View {
    let days: Int
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: TBDTokens.Space.xs) {
            TextField("30", text: $text).tbdField().frame(width: 48)
                .onSubmit { apply(Int(text) ?? days) }
            Stepper("", value: Binding(get: { days }, set: { apply($0) }), in: TBDRetentionPolicy.dayRange).labelsHidden()
            Text(days == 1 ? "day" : "days").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
        }
        .onAppear { text = "\(days)" }
        .onChange(of: days) { _, value in text = "\(value)" }
    }

    private func apply(_ value: Int) {
        let clamped = min(max(value, TBDRetentionPolicy.dayRange.lowerBound), TBDRetentionPolicy.dayRange.upperBound)
        text = "\(clamped)"
        if clamped != days { commit(clamped) }
    }
}
