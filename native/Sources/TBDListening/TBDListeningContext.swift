import AppKit
import TBDSpeech

/// Owns the Listening controllers and wires hotkeys and menu actions to them.
@MainActor
final class TBDListeningContext {
    let env = TBDListeningEnvironment()
    let dictation: TBDDictationController
    let voice: TBDVoiceCapture
    let meetings: TBDMeetingController
    let files: TBDFileQueue
    let transforms: TBDTransformController
    let retention: TBDRetentionController
    private var savedEffects: TBDTranscriptSavedEffects?
    let knowledge: TBDKnowledgeController
    private let hotkeys = TBDHotkeyMonitor()
    let hotkeyCoordinator: TBDHotkeyCoordinator
    private weak var runtime: TBDListeningRuntime?
    private(set) var hotkeysActive = false

    init(runtime: TBDListeningRuntime) {
        self.runtime = runtime
        dictation = TBDDictationController(env: env)
        voice = TBDVoiceCapture(env: env)
        meetings = TBDMeetingController(env: env)
        files = TBDFileQueue(env: env)
        transforms = TBDTransformController(env: env)
        retention = TBDRetentionController(env: env)
        hotkeyCoordinator = TBDHotkeyCoordinator(preferences: env.preferences, currentFlags: { TBDHotkeyMonitor.currentFlags },
                                                 physicalKeyState: TBDHotkeyMonitor.keyIsDown)
        knowledge = TBDKnowledgeController(database: env.database, preferences: env.preferences,
                                           saver: { [weak runtime] in runtime?.saveToKnowledge })
        let report: (String) -> Void = { [weak runtime] in runtime?.report($0) }
        meetings.onMessage = report
        files.onMessage = report
        transforms.onMessage = report
        retention.onMessage = report
        let meetings = self.meetings
        savedEffects = TBDTranscriptSavedEffects(env: env, notifier: env.notifier, report: report,
                                                 canPresentMeetingEnd: { meetings.canPresentMeetingEnd })
        meetings.onBringToFront = { [weak runtime] in runtime?.bringToFront() }
        dictation.isMeetingRecording = { [weak self] in self?.meetings.isRecording ?? false }
        knowledge.onMessage = report
        // Save to Knowledge auto rule: one more handler on the transcript-saved hub.
        env.transcriptSaved.add { [weak knowledge] item in knowledge?.autoSave(item) }
        hotkeys.onStatusChange = { [weak self] in self?.hotkeysActive = $0 }
        wireHotkeys()
    }

    var isCapturing: Bool { dictation.isRecording || voice.chatActive || voice.noteRecording || meetings.isRecording }

    func start() {
        reloadHotkeys()
        dictation.settingsChanged()
        meetings.start()
        retention.start()
        Task { await env.speech.warmUp() }
    }

    func stop() {
        hotkeys.stop()
        retention.stop()
        dictation.cancel()
        dictation.shutdown()
        meetings.shutdown()
        files.cancelAll()
        Task { await env.speech.shutdown() }
    }

    /// Re-reads hotkey preferences (TBDHotkeyCoordinator). Invalid strings disable that hotkey.
    func reloadHotkeys() { hotkeyCoordinator.refreshAll() }

    private func wireHotkeys() {
        hotkeyCoordinator.targets = self
        hotkeyCoordinator.onChange = { [weak self] hasHotkeys, activeTap in
            guard let self else { return }
            self.hotkeys.set(activeTap: activeTap, handler: hasHotkeys ? { [weak self] in self?.hotkeyCoordinator.handle($0) ?? false } : nil)
        }
        dictation.onHotkeysReset = { [weak self] in self?.hotkeyCoordinator.resetDictationGestures() }
        dictation.onCancelledByUI = { [weak self] in self?.hotkeyCoordinator.notifyCancelledByUI() }
        dictation.onStartedOutsideHotkey = { [weak self] in self?.hotkeyCoordinator.syncRecordingMode($0) }
        // One hotkey per Transform (Transforms page), registered by the coordinator after the reserved hotkeys.
        hotkeyCoordinator.transformPrompts = { [weak self] in (try? self?.env.database?.prompts(category: .transform)) ?? [] }
    }

    func report(_ message: String) { runtime?.report(message) }

    var hotkeyPermissionMissing: Bool { !hotkeys.isActive }

    func perform(_ action: TBDListeningAction) {
        switch action.effect {
        case .toggleDictation: dictation.toggle()
        case .toggleMeeting: meetings.toggle()
        case .pickFiles: show(.transcribe); files.pickFiles()
        case .promptForURL: show(.transcribe); files.promptForURL()
        case .chooseTransform: transforms.chooseAndRun()
        case .meetingControls:
            switch TBDListeningAction.meetingControlsTarget(isRecording: meetings.isRecording) {
            case .floatingPanel: meetings.showPanel()
            case .meetingsPage: show(.meetings)
            }
        case .show(let page): show(TBDListeningTab(rawValue: page) ?? .library)
        }
    }

    private func show(_ tab: TBDListeningTab) {
        env.selectedTab = tab
        runtime?.bringToFront()
    }

    func bringToFront() { runtime?.bringToFront() }
}
