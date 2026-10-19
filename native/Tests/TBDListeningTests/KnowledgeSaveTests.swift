import XCTest
import TBDSpeech
@testable import TBDListening

/// WP10 "Save to Knowledge": request building, the automatic rule and failure reporting.
@MainActor
final class KnowledgeSaveTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func transcript(kind: TBDSourceKind, url: String? = nil, status: TBDTranscriptionStatus = .completed) -> TBDTranscription {
        var item = TBDTranscription(id: "0f6c1b2a-3d4e-4f50-8a9b-0c1d2e3f4a5b", title: "Weekly planning", sourceKind: kind, sourceURL: url, status: status)
        item.createdAt = Date(timeIntervalSince1970: 1_791_797_400) // 2026-10-12 09:30 UTC
        item.durationMs = 724_000
        item.rawText = "Hello team."
        return item
    }

    private func preferences() throws -> (TBDListeningPreferences, () -> Void) {
        let suite = "tbd.tests.knowledge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (TBDListeningPreferences(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: Request building

    func testRequestHasExactTitleHeaderBodySummaryAndTags() {
        let item = transcript(kind: .url, url: "https://www.youtube.com/watch?v=abc")
        let request = TBDKnowledgeDocument.request(for: item, title: "  Planning notes ", tags: ["#Planning", " Team Sync ", "planning", ""], timeZone: utc)
        XCTAssertEqual(request, TBDKnowledgeSaveRequest(
            transcriptId: "0f6c1b2a-3d4e-4f50-8a9b-0c1d2e3f4a5b",
            title: "Planning notes",
            body: "Source: https://www.youtube.com/watch?v=abc\nDate: 2026-10-12 09:30\nKind: Link\nDuration: 12:04\n\nHello team.",
            summary: "Link · 2026-10-12 09:30 · 12:04 · https://www.youtube.com/watch?v=abc",
            tags: ["planning", "team-sync"]))
        XCTAssertEqual(request.payload["tags"] as? [String], ["planning", "team-sync"])
        XCTAssertEqual(request.payload["transcriptId"] as? String, "0f6c1b2a-3d4e-4f50-8a9b-0c1d2e3f4a5b")
    }

    func testMeetingWithoutLinkHasNoSourceLineAndABlankTitleKeepsTheTranscriptTitle() {
        var item = transcript(kind: .meeting)
        item.durationMs = 0
        let request = TBDKnowledgeDocument.request(for: item, title: "   ", tags: [], timeZone: utc)
        XCTAssertEqual(request.title, "Weekly planning")
        XCTAssertEqual(request.body, "Date: 2026-10-12 09:30\nKind: Meeting\n\nHello team.")
        XCTAssertEqual(request.summary, "Meeting · 2026-10-12 09:30")
        XCTAssertEqual(request.tags, [])
    }

    func testSuggestedTagsAreParsedFromAModelReply() {
        XCTAssertEqual(TBDKnowledgeTags.parse("1. Planning\n2. Budget Review\n#q3, 2026-roadmap; - Hiring\nextra\nmore"),
                       ["planning", "budget-review", "q3", "2026-roadmap", "hiring"])
        XCTAssertEqual(TBDKnowledgeTags.normalize([String(repeating: "a", count: 50)]), [String(repeating: "a", count: 40)])
    }

    func testHelperReplyParsing() {
        XCTAssertEqual(TBDKnowledgeSaveResult(payload: ["documentId": "kdoc_1", "area": "agt-tbd"]), TBDKnowledgeSaveResult(documentId: "kdoc_1", area: "agt-tbd"))
        XCTAssertNil(TBDKnowledgeSaveResult(payload: ["area": "agt-tbd"]))
        XCTAssertNil(TBDKnowledgeSaveResult(payload: NSNull()))
    }

    // MARK: Automatic rule

    func testAutoSaveRunsOnlyForEnabledKindsAndOnlyOncePerTranscript() async throws {
        let database = try TBDListeningDatabase(inMemory: ())
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        var sent: [TBDKnowledgeSaveRequest] = []
        let controller = TBDKnowledgeController(database: database, preferences: prefs, saver: {
            { request, _ in sent.append(request); return TBDKnowledgeSaveResult(documentId: "kdoc_1", area: "agt-tbd") }
        }, suggest: { _ in ["planning"] })
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }

        let link = transcript(kind: .url, url: "https://example.com/v")
        try database.save(link)
        var file = transcript(kind: .file); file.id = "file-1"
        try database.save(file)

        // Default off: nothing is saved.
        XCTAssertFalse(prefs.autoSaveLinksToKnowledge)
        XCTAssertFalse(prefs.autoSaveMeetingsToKnowledge)
        XCTAssertNil(controller.autoSave(link))

        prefs.autoSaveLinksToKnowledge = true
        XCTAssertNil(controller.autoSave(file), "file transcripts are not an automatic kind")
        var meeting = transcript(kind: .meeting); meeting.id = "meeting-1"
        try database.save(meeting)
        XCTAssertNil(controller.autoSave(meeting), "meetings are off")
        XCTAssertNil(controller.autoSave(transcript(kind: .url, status: .failed)), "unfinished transcripts are skipped")

        let first = try XCTUnwrap(controller.autoSave(link))
        XCTAssertNil(controller.autoSave(link), "a save in flight is not started twice")
        await first.value
        XCTAssertNil(controller.autoSave(link), "a saved transcript is never saved again")

        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.tags, ["planning"])
        XCTAssertEqual(sent.first?.title, "Weekly planning")
        let stored = try XCTUnwrap(database.knowledgeLink(transcriptionId: link.id))
        XCTAssertEqual(stored.documentId, "kdoc_1")
        XCTAssertEqual(stored.area, "agt-tbd")
        XCTAssertEqual(messages, [])
        XCTAssertEqual(controller.status, [:])

        prefs.autoSaveMeetingsToKnowledge = true
        let second = try XCTUnwrap(controller.autoSave(meeting))
        await second.value
        XCTAssertEqual(sent.map(\.transcriptId), [link.id, "meeting-1"])

        // The link goes with the transcript.
        try database.deleteTranscription(id: link.id)
        XCTAssertNil(try database.knowledgeLink(transcriptionId: link.id))
    }

    func testAutoSaveFailureSurfacesAPlainMessageAndStoresNothing() async throws {
        let database = try TBDListeningDatabase(inMemory: ())
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        prefs.autoSaveMeetingsToKnowledge = true
        let controller = TBDKnowledgeController(database: database, preferences: prefs, saver: {
            { _, _ in throw TBDKnowledgeError("TBD's agent has no Knowledge access.") }
        }, suggest: { _ in [] })
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        let meeting = transcript(kind: .meeting)
        try database.save(meeting)

        await controller.autoSave(meeting)?.value
        XCTAssertEqual(messages, ["Save to Knowledge failed for “Weekly planning”: TBD's agent has no Knowledge access."])
        XCTAssertEqual(controller.failures[meeting.id], "TBD's agent has no Knowledge access.")
        XCTAssertNil(try database.knowledgeLink(transcriptionId: meeting.id))
        XCTAssertTrue(controller.shouldAutoSave(meeting), "a failed save can run again")
    }

    func testWithoutAHostSaverTheMessageAsksToSignIn() async throws {
        let database = try TBDListeningDatabase(inMemory: ())
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        prefs.autoSaveLinksToKnowledge = true
        let controller = TBDKnowledgeController(database: database, preferences: prefs, saver: { nil }, suggest: { _ in [] })
        var messages: [String] = []
        controller.onMessage = { messages.append($0) }
        let link = transcript(kind: .url, url: "https://example.com/v")
        try database.save(link)
        await controller.autoSave(link)?.value
        XCTAssertEqual(messages, ["Save to Knowledge failed for “Weekly planning”: Sign in to Teal Brick in TBD first."])
    }

    /// C282: when Knowledge is not paid for (or not installed), nothing is sent: no automatic save, no manual save.
    func testLockedKnowledgeBlocksManualAndAutomaticSaves() async throws {
        let database = try TBDListeningDatabase(inMemory: ())
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        prefs.autoSaveLinksToKnowledge = true
        var sent = 0
        let controller = TBDKnowledgeController(database: database, preferences: prefs, saver: {
            { _, _ in sent += 1; return TBDKnowledgeSaveResult(documentId: "doc_1", area: "inbox") }
        }, suggest: { _ in [] })
        controller.availability = "Available with Knowledge."
        let link = transcript(kind: .url, url: "https://example.com/v")
        try database.save(link)
        XCTAssertFalse(controller.shouldAutoSave(link))
        XCTAssertNil(controller.autoSave(link))
        let request = TBDKnowledgeSaveRequest(transcriptId: link.id, title: "Weekly planning", body: "Hello team.", summary: "", tags: [])
        do {
            try await controller.save(request)
            XCTFail("a locked Knowledge must refuse the save")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Available with Knowledge.")
        }
        XCTAssertEqual(sent, 0)
        controller.availability = nil
        XCTAssertTrue(controller.shouldAutoSave(link), "unlocked again: the automatic rule applies")
    }

    func testManualSaveReportsWaitingStatusAndStoresTheDocument() async throws {
        let database = try TBDListeningDatabase(inMemory: ())
        let (prefs, cleanup) = try preferences()
        defer { cleanup() }
        var seen: [String] = []
        var controllerRef: TBDKnowledgeController?
        let controller = TBDKnowledgeController(database: database, preferences: prefs, saver: {
            { request, status in
                status("Waiting for owner approval")
                seen.append(controllerRef?.status[request.transcriptId] ?? "")
                return TBDKnowledgeSaveResult(documentId: "kdoc_2")
            }
        }, suggest: { _ in [] })
        controllerRef = controller
        let item = transcript(kind: .file)
        try database.save(item)
        let result = try await controller.save(TBDKnowledgeDocument.request(for: item, title: "Notes", tags: ["x"], timeZone: utc))
        XCTAssertEqual(result, TBDKnowledgeSaveResult(documentId: "kdoc_2"))
        XCTAssertEqual(seen, ["Waiting for owner approval"])
        XCTAssertEqual(controller.status, [:])
        XCTAssertEqual(try database.knowledgeLink(transcriptionId: item.id)?.documentId, "kdoc_2")
        XCTAssertFalse(controller.shouldAutoSave(item))
    }
}
