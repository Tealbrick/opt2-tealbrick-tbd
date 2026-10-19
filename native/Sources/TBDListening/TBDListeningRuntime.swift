import AppKit
import SwiftUI
import TBDDesign
import TBDSpeech

/// Native embedding facade for Listening. Retain one instance for the host lifetime.
/// The public shape is the contract with Companion.
@MainActor
public final class TBDListeningRuntime: ObservableObject {
    public static let shared = TBDListeningRuntime()
    public var activate: (() -> Void)?
    @Published public private(set) var voiceNoteRecording = false
    @Published public private(set) var captureBusy = false
    @Published public private(set) var captureMessage = ""
    @Published public private(set) var lastRawTranscript = ""

    private var started = false
    private var context: TBDListeningContext?

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        let context = TBDListeningContext(runtime: self)
        self.context = context
        context.knowledge.availability = knowledgeAvailability
        context.voice.onMessage = { [weak self] in self?.captureMessage = $0 }
        context.voice.onRawTranscript = { [weak self] in self?.lastRawTranscript = $0 }
        context.start()
        // Weekly yt-dlp refresh at launch, as v1 did; never blocks and ignores failures.
        let preferences = context.env.preferences
        Task.detached(priority: .utility) { await TBDBinaryBootstrap(defaults: preferences.defaults).autoUpdateYtDlpIfNeeded() }
    }

    public func content() -> AnyView {
        guard let context else { return AnyView(Text("Listen is starting…").foregroundStyle(TBDTokens.muted)) }
        return AnyView(TBDListeningView(context: context).environmentObject(context.env))
    }

    /// Screenshots and design checks only (tbd-design-shots): the Listening UI on a scratch library, without starting
    /// capture, hotkeys, meetings, retention, imports or downloads. Refuses unless TBD_LISTENING_ROOT points at a scratch
    /// root, so it can never open the person's library. `tab`: a `TBDListeningTab` raw value; `transcriptID` opens one item.
    public func previewContent(tab: String, transcriptID: String? = nil) -> AnyView {
        guard let context = previewContext() else { return AnyView(Text("Preview needs TBD_LISTENING_ROOT")) }
        context.env.selectedTab = TBDListeningTab(rawValue: tab) ?? .transcribe
        context.env.selectedTranscriptionID = transcriptID
        return AnyView(TBDListeningView(context: context).environmentObject(context.env))
    }

    /// Settings sections for screenshots, with the same guard as `previewContent`.
    public func previewSettings(section: String) -> AnyView {
        guard let context = previewContext() else { return AnyView(Text("Preview needs TBD_LISTENING_ROOT")) }
        return AnyView(TBDListeningSettingsView(section: section, context: context).environmentObject(context.env))
    }

    private func previewContext() -> TBDListeningContext? {
        guard !started, let root = ProcessInfo.processInfo.environment[TBDListeningPaths.rootEnvironmentKey], !root.isEmpty else { return nil }
        if let context { return context }
        let context = TBDListeningContext(runtime: self)
        self.context = context
        return context
    }

    /// Sections: `TBDListeningSettingsSection` raw values ("capture", "engine", "ai", "dictation", "meetings", "system").
    public func settingsContent(section: String, scrolls: Bool = true) -> AnyView {
        guard let context else { return AnyView(EmptyView()) }
        return AnyView(TBDListeningSettingsView(section: section, context: context, scrolls: scrolls).environmentObject(context.env))
    }

    /// Refuses to quit while speech is being captured or saved.
    public func shouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard started, let context else { return .terminateNow }
        if voiceNoteRecording || captureBusy || context.isCapturing {
            let alert = NSAlert()
            alert.messageText = "Speech capture in progress"
            alert.informativeText = "Finish saving your speech capture before quitting."
            alert.addButton(withTitle: "Keep running")
            alert.runModal()
            return .terminateCancel
        }
        return .terminateNow
    }

    public var meetingStatus: String { context?.meetings.statusText ?? "Idle" }

    /// Actions: "dictation", "meeting", "transcribeFile", "transcribeURL", "transform", "openLibrary".
    public func menuAction(_ action: TBDListeningAction) {
        guard let context else { captureMessage = "Listen is still starting"; return }
        context.perform(action)
    }

    public func toggleVoiceNote() async {
        guard !captureBusy else { return }
        guard let context else { captureMessage = "Listen is still starting"; return }
        captureBusy = true; captureMessage = ""
        defer { captureBusy = false }
        do {
            if context.voice.noteRecording {
                voiceNoteRecording = false
                let status = try await context.voice.finishNote()
                if captureMessage.isEmpty { captureMessage = status }
            } else {
                try await context.voice.startNote()
                voiceNoteRecording = true
            }
        } catch {
            voiceNoteRecording = context.voice.noteRecording
            captureMessage = error.localizedDescription
        }
    }

    /// Chat dictation: "start" → NSNull, "level" → Float, "cancel" → NSNull, "stop" → ["text", "rawText", "warning"].
    public func chatAudio(_ operation: String) async throws -> Any {
        guard let context else { throw TBDVoiceCapture.error(1, "Listen is still starting") }
        return try await context.voice.chat(operation)
    }

    public func terminate() {
        guard started, let context else { return }
        context.stop()
        started = false
    }

    // MARK: Additions

    /// Hotkey dictation is recording or transcribing.
    public var dictationActive: Bool { context?.dictation.isBusy ?? false }

    // MARK: knowledge

    /// Set by the host: sends a "Save to Knowledge" request to the Chat helper, which calls
    /// Knowledge as TBD's own agent. Nil (no host, not signed in) makes saves fail with a plain message.
    public var saveToKnowledge: TBDKnowledgeSaver?
    /// Set by the host from the workspace's entitlements (C282): nil = Knowledge is available, else the sentence
    /// ("Available with Knowledge."). Locks the button and the automatic saves.
    /// nil until the host has read the plan: an unread plan never locks Save to Knowledge (C282 fail-safe, review
    /// dev.12 #3); Core still refuses an unpaid save.
    public var knowledgeAvailability: String? = nil {
        didSet { context?.knowledge.availability = knowledgeAvailability }
    }

    func report(_ message: String) { captureMessage = message }
    func bringToFront() { activate?() }
}
