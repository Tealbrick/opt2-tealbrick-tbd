import Foundation
import TBDModels
import TBDSpeech

/// The speech model for dictation and meetings, for the first-launch onboarding (WP-ONB step 4). The app does not
/// link TBDSpeech; this is its one door. A download started here keeps running when the person goes on (C286 F3):
/// the shared instance owns the task, and the summary reads `progress`.
@MainActor
public final class TBDSpeechModelSetup: ObservableObject {
    public static let shared = TBDSpeechModelSetup()

    /// 0...1 while the download runs; nil otherwise.
    @Published public private(set) var progress: Double?
    @Published public private(set) var error: String?
    @Published public private(set) var ready = false

    /// The default engine's model (Parakeet v3).
    public let model = TBDModelManager.Model.parakeetV3
    public var title: String { model.title }
    /// "640 MB" style size of the download.
    public var size: String { ByteCountFormatter.string(fromByteCount: Int64(model.approximateBytes), countStyle: .file) }

    private var manager: TBDModelManager { TBDModelManager(preferences: TBDListeningPreferences()) }

    private init() { refresh() }

    /// Ready when the engine the person uses has its model on disk.
    public func refresh() {
        ready = manager.isDownloaded(engine: TBDListeningPreferences().engine) || manager.isDownloaded(model)
    }

    /// Starts the download once; a second call while it runs does nothing.
    public func download() {
        guard progress == nil, !ready else { return }
        progress = 0
        error = nil
        let manager = self.manager, model = self.model
        Task {
            do {
                try await manager.download(model) { value in Task { @MainActor in if self.progress != nil { self.progress = value } } }
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
            refresh()
        }
    }
}
