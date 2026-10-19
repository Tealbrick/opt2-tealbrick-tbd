import Foundation
import TBDSpeech

/// Saves transcripts to Knowledge: from the detail view's sheet and automatically for the kinds the
/// person switched on (meetings, links). The created document id is stored per transcript, so the
/// button shows "Saved to Knowledge" and an automatic save never runs twice. Failures are always
/// reported (L3): in the sheet, or as a Listening message for automatic saves.
@MainActor
final class TBDKnowledgeController: ObservableObject {
    /// Progress per transcript id ("Saving…", "Waiting for owner approval").
    @Published private(set) var status: [String: String] = [:]
    /// Last failure per transcript id, shown next to the button.
    @Published private(set) var failures: [String: String] = [:]
    /// Bumped when a link is stored so views reload.
    @Published private(set) var revision = 0
    /// Nil when Knowledge is paid for and running in the workspace; else the sentence to show (C282), set by the host.
    @Published var availability: String?
    var onMessage: ((String) -> Void)?

    private let database: TBDListeningDatabase?
    private let preferences: TBDListeningPreferences
    private let saver: () -> TBDKnowledgeSaver?
    private let suggester: (TBDTranscription) async -> [String]

    init(database: TBDListeningDatabase?, preferences: TBDListeningPreferences, saver: @escaping () -> TBDKnowledgeSaver?,
         suggest: @escaping (TBDTranscription) async -> [String] = TBDKnowledgeTags.suggest) {
        self.database = database
        self.preferences = preferences
        self.saver = saver
        self.suggester = suggest
    }

    func link(for transcriptionId: String) -> TBDKnowledgeLink? { try? database?.knowledgeLink(transcriptionId: transcriptionId) }
    func isSaving(_ transcriptionId: String) -> Bool { status[transcriptionId] != nil }
    func suggestTags(_ item: TBDTranscription) async -> [String] { await suggester(item) }

    /// Sends one request and stores the created document id. Throws a plain message.
    @discardableResult
    func save(_ request: TBDKnowledgeSaveRequest) async throws -> TBDKnowledgeSaveResult {
        let id = request.transcriptId
        if let existing = link(for: id) { return TBDKnowledgeSaveResult(documentId: existing.documentId, area: existing.area) }
        guard !isSaving(id) else { throw TBDKnowledgeError("This transcript is already being saved to Knowledge.") }
        if let availability { throw TBDKnowledgeError(availability) }
        guard let saver = saver() else { throw TBDKnowledgeError.signIn }
        status[id] = "Saving…"
        failures[id] = nil
        defer { status[id] = nil }
        do {
            let result = try await saver(request) { [weak self] message in self?.status[id] = message }
            try database?.save(TBDKnowledgeLink(transcriptionId: id, documentId: result.documentId, area: result.area))
            revision &+= 1
            return result
        } catch {
            failures[id] = error.localizedDescription
            throw error
        }
    }

    /// True for a finished transcript of an enabled kind that was not saved yet and is not being saved.
    func shouldAutoSave(_ item: TBDTranscription) -> Bool {
        availability == nil && item.status == .completed && preferences.autoSavesToKnowledge(item.sourceKind)
            && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSaving(item.id) && link(for: item.id) == nil
    }

    /// The "transcript saved" observer: saves with the suggested tags, without the sheet.
    @discardableResult
    func autoSave(_ item: TBDTranscription) -> Task<Void, Never>? {
        guard shouldAutoSave(item) else { return nil }
        status[item.id] = "Saving…" // claims the transcript before the tag suggestion runs
        return Task { [weak self] in
            guard let self else { return }
            let tags = await self.suggester(item)
            self.status[item.id] = nil
            let request = TBDKnowledgeDocument.request(for: item, title: item.title, tags: tags)
            do {
                try await self.save(request)
            } catch is CancellationError {
            } catch {
                self.onMessage?("Save to Knowledge failed for “\(item.title)”: \(error.localizedDescription)")
            }
        }
    }
}
