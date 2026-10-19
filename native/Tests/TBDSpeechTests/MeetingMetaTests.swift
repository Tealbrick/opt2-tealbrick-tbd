import Foundation
import GRDB
import TBDModels
import XCTest
@testable import TBDSpeech

/// Records every request and answers with a fixed string, or throws (no network).
private final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TBDCompletionRequest] = []
    let reply: Result<String, Error>
    init(_ reply: String) { self.reply = .success(reply) }
    init(failing error: Error) { reply = .failure(error) }
    var requests: [TBDCompletionRequest] { lock.withLock { stored } }
    var complete: TBDCompleter {
        { [self] request in
            lock.withLock { stored.append(request) }
            return try reply.get()
        }
    }
}

private struct ModelDown: Error {}

// MARK: - Automatic meeting titles

final class MeetingTitleTests: XCTestCase {
    private let longTranscript = (1...30).map { "word\($0)" }.joined(separator: " ")

    func testFallbackTitlesAreReplacedAndRealTitlesAreNot() {
        let replaced = ["Meeting", "meeting", "  Meeting  ", "Meeting Oct 13, 2026 at 9:59 AM", "Meeting Jun 17, 2026 at 09:59",
                        "Meeting 09:59", "Meeting 12/03/2026", "Meeting December", "MEETING Sept 3"]
        for title in replaced { XCTAssertTrue(TBDMeetingTitle.shouldReplaceFallback(title), title) }
        let kept = ["Weekly sync", "Meeting 2026 Budget Planning", "Meeting with Anna", "Meetings", "Budget meeting Oct 13 at 9:59", "", "Team Meeting"]
        for title in kept { XCTAssertFalse(TBDMeetingTitle.shouldReplaceFallback(title), title) }
    }

    func testValidatedTitleAcceptsCleanTitles() {
        XCTAssertEqual(TBDMeetingTitle.validated(from: "Quarterly Budget Review"), "Quarterly Budget Review")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "  \"Quarterly Budget Review\"  "), "Quarterly Budget Review")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "Quarterly Budget Review."), "Quarterly Budget Review")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "“Launch plan for Atlas”"), "Launch plan for Atlas")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "'\"Nested quotes here\"'"), "Nested quotes here")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "- Hiring pipeline update"), "Hiring pipeline update")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "* Hiring pipeline update"), "Hiring pipeline update")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "2. Vendor contract renewal!"), "Vendor contract renewal")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "Roadmap:  sync   with   design?"), "Roadmap: sync with design")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "\n\nBudget review call\n\n"), "Budget review call")
        XCTAssertEqual(TBDMeetingTitle.validated(from: "One two three four five six seven eight"), "One two three four five six seven eight")
    }

    func testValidatedTitleRejectsBadAnswers() {
        let bad = [
            "", "   ", "NO_TITLE", "no title", "No Title.", "Not enough context", "Not enough context to name this meeting",
            "Meeting", "Meeting notes", "Discussion", "Transcript", "Summary", "Conversation", "Call", "Audio transcript",
            "Budget",                                                  // one word
            "One two three four five six seven eight nine",            // nine words
            "Budget review 2026", "Standup at 10:30", "Review of 12/03/2026",
            "Line one here\nLine two here",                           // two lines
            String(repeating: "abcdefghij ", count: 7).trimmingCharacters(in: .whitespaces) + "x",   // 78 characters
        ]
        for answer in bad { XCTAssertNil(TBDMeetingTitle.validated(from: answer), answer) }
    }

    func testTitleLengthLimitIs70Characters() {
        let seventy = String(repeating: "abcdefghi ", count: 7).trimmingCharacters(in: .whitespaces)   // 69 characters
        XCTAssertEqual(seventy.count, 69)
        XCTAssertEqual(TBDMeetingTitle.validated(from: seventy), seventy)
        let exact70 = seventy + "x"
        XCTAssertEqual(exact70.count, 70)
        XCTAssertEqual(TBDMeetingTitle.validated(from: exact70), exact70)
        XCTAssertNil(TBDMeetingTitle.validated(from: exact70 + "y"))
    }

    func testPromptKeepsStartAndEndOfLongTranscripts() {
        let short = String(repeating: "a", count: 24_000)
        XCTAssertEqual(TBDMeetingTitle.truncatedForPrompt(short), short)
        let long = String(repeating: "a", count: 12_000) + String(repeating: "m", count: 5) + String(repeating: "z", count: 12_000)
        let cut = TBDMeetingTitle.truncatedForPrompt(long)
        XCTAssertEqual(cut, String(repeating: "a", count: 12_000) + "\n\n[...]\n\n" + String(repeating: "z", count: 12_000))
        XCTAssertEqual(cut.count, 24_009)
    }

    func testRequestUsesTheAnalysisRouteWithTheV1Rules() {
        let request = TBDMeetingTitle.request(transcript: "  hello \n\n there  ")
        XCTAssertEqual(request.task, .analysis)
        XCTAssertEqual(request.maxTokens, 256)
        XCTAssertNil(request.temperature)
        XCTAssertNil(request.modelOverride)
        XCTAssertEqual(request.messages.count, 2)
        XCTAssertEqual(request.messages[0].role, .system)
        XCTAssertEqual(request.messages[0].content, TBDMeetingTitle.systemPrompt)
        XCTAssertEqual(request.messages[1].role, .user)
        XCTAssertEqual(request.messages[1].content, "Transcript:\nhello there")
        XCTAssertTrue(TBDMeetingTitle.systemPrompt.hasPrefix("Generate a concise title for this meeting transcript."))
        XCTAssertTrue(TBDMeetingTitle.systemPrompt.contains("Use 2 to 8 words."))
        XCTAssertTrue(TBDMeetingTitle.systemPrompt.contains("return NO_TITLE."))
    }

    func testGenerateReturnsTheCleanedTitle() async throws {
        let model = FakeModel("\"Quarterly Budget Review\"\n")
        let title = try await TBDMeetingTitle.generate(transcript: longTranscript, currentTitle: "Meeting Oct 13, 2026 at 9:59 AM", complete: model.complete)
        XCTAssertEqual(title, "Quarterly Budget Review")
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.requests[0].messages[1].content, "Transcript:\n" + longTranscript)
    }

    func testGenerateNeverCallsTheModelForATitleThePersonSet() async throws {
        let model = FakeModel("Quarterly Budget Review")
        let title = try await TBDMeetingTitle.generate(transcript: longTranscript, currentTitle: "Weekly sync with Anna", complete: model.complete)
        XCTAssertNil(title)
        XCTAssertEqual(model.requests.count, 0)
    }

    func testGenerateNeedsTwelveWords() async throws {
        let model = FakeModel("Quarterly Budget Review")
        let eleven = (1...11).map { "w\($0)" }.joined(separator: " ")
        let twelve = (1...12).map { "w\($0)" }.joined(separator: " ")
        let none = try await TBDMeetingTitle.generate(transcript: eleven, currentTitle: "Meeting", complete: model.complete)
        XCTAssertNil(none)
        XCTAssertEqual(model.requests.count, 0)
        let some = try await TBDMeetingTitle.generate(transcript: twelve, currentTitle: "Meeting", complete: model.complete)
        XCTAssertEqual(some, "Quarterly Budget Review")
        XCTAssertEqual(model.requests.count, 1)
    }

    func testGenerateKeepsTheFallbackWhenTheAnswerIsUnusable() async throws {
        for answer in ["NO_TITLE", "Meeting", "Budget", "Two\nLines here", "Planning for 2026 goals"] {
            let title = try await TBDMeetingTitle.generate(transcript: longTranscript, currentTitle: "Meeting", complete: FakeModel(answer).complete)
            XCTAssertNil(title, answer)
        }
    }

    func testGenerateTreatsAModelErrorAsNoTitleButPassesCancellationOn() async throws {
        let none = try await TBDMeetingTitle.generate(transcript: longTranscript, currentTitle: "Meeting", complete: FakeModel(failing: ModelDown()).complete)
        XCTAssertNil(none)
        do {
            _ = try await TBDMeetingTitle.generate(transcript: longTranscript, currentTitle: "Meeting", complete: FakeModel(failing: CancellationError()).complete)
            XCTFail("cancellation must reach the caller")
        } catch is CancellationError {}
    }

    func testSettingDefaultsOnAndWritesNothingUntilChanged() throws {
        let suite = "tbd.tests.meetingtitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TBDListeningPreferences(defaults: defaults)
        XCTAssertEqual(TBDListeningPreferences.autoGenerateMeetingTitlesKey, "tbd.listening.autoGenerateMeetingTitles")
        XCTAssertTrue(prefs.autoGenerateMeetingTitles)
        XCTAssertNil(defaults.object(forKey: "tbd.listening.autoGenerateMeetingTitles"), "reading the default stores nothing")
        prefs.autoGenerateMeetingTitles = false
        XCTAssertFalse(prefs.autoGenerateMeetingTitles)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.autoGenerateMeetingTitles") as? Bool, false)
        prefs.autoGenerateMeetingTitles = true
        XCTAssertTrue(prefs.autoGenerateMeetingTitles)
    }

    func testApplyingATitleNeverOverwritesAPersonsTitle() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let fallback = TBDTranscription(title: "Meeting Oct 13, 2026 at 9:59 AM", sourceKind: .meeting, status: .completed)
        let renamed = TBDTranscription(title: "Board prep", sourceKind: .meeting, status: .completed)
        let file = TBDTranscription(title: "Meeting", sourceKind: .file, status: .completed)
        for item in [fallback, renamed, file] { try db.save(item) }

        XCTAssertTrue(try db.applyGeneratedMeetingTitle("Quarterly Budget Review", to: fallback.id))
        XCTAssertEqual(try db.transcription(id: fallback.id)?.title, "Quarterly Budget Review")
        // Applying again, or after the person renamed the meeting, changes nothing.
        XCTAssertFalse(try db.applyGeneratedMeetingTitle("Another Title Here", to: fallback.id))
        XCTAssertFalse(try db.applyGeneratedMeetingTitle("Another Title Here", to: renamed.id))
        XCTAssertEqual(try db.transcription(id: renamed.id)?.title, "Board prep")
        XCTAssertFalse(try db.applyGeneratedMeetingTitle("Another Title Here", to: file.id), "only meetings are named")
        XCTAssertEqual(try db.transcription(id: file.id)?.title, "Meeting")
        XCTAssertFalse(try db.applyGeneratedMeetingTitle("Another Title Here", to: "missing"))
    }
}

// MARK: - Labels

final class MeetingLabelTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var prefs: TBDListeningPreferences!

    override func setUpWithError() throws {
        suite = "tbd.tests.labels.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        prefs = TBDListeningPreferences(defaults: defaults)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func library() throws -> TBDListeningDatabase {
        let db = try TBDListeningDatabase(inMemory: ())
        try db.preparePromptLibrary(preferences: prefs)
        return db
    }

    @discardableResult
    private func transcript(_ db: TBDListeningDatabase, _ title: String, kind: TBDSourceKind = .meeting) throws -> TBDTranscription {
        let item = TBDTranscription(title: title, sourceKind: kind, status: .completed)
        try db.save(item)
        return item
    }

    // MARK: Pure rules

    func testNamesAreTrimmedAndMustBeNew() throws {
        XCTAssertEqual(try TBDLabelRules.normalizedName("  Customer \n"), "Customer")
        XCTAssertThrowsError(try TBDLabelRules.normalizedName("   ")) { XCTAssertEqual($0 as? TBDLabelError, .emptyName) }
        let labels = [TBDMeetingLabel(id: "a", name: "Café"), TBDMeetingLabel(id: "b", name: "Internal")]
        XCTAssertTrue(TBDLabelRules.isDuplicate("CAFE", among: labels), "case and accents are ignored")
        XCTAssertTrue(TBDLabelRules.isDuplicate("internal", among: labels))
        XCTAssertFalse(TBDLabelRules.isDuplicate("Internal", among: labels, excluding: "b"), "a label may keep its own name")
        XCTAssertFalse(TBDLabelRules.isDuplicate("Internals", among: labels))
    }

    func testOrderAndSearch() {
        let labels = [TBDMeetingLabel(id: "1", name: "zeta", sortOrder: 0), TBDMeetingLabel(id: "2", name: "Beta", sortOrder: 1),
                      TBDMeetingLabel(id: "3", name: "alpha", sortOrder: 1), TBDMeetingLabel(id: "4", name: "Gamma", sortOrder: 0)]
        XCTAssertEqual(TBDLabelRules.ordered(labels).map(\.id), ["4", "1", "3", "2"])
        XCTAssertEqual(TBDLabelRules.matching("ET", in: labels).map(\.name), ["zeta", "Beta"])
        XCTAssertEqual(TBDLabelRules.matching("  ", in: labels).count, 4)
        XCTAssertEqual(TBDLabelRules.matching("nope", in: labels).count, 0)
    }

    func testColorTokensFollowV1() {
        XCTAssertEqual(TBDLabelColor(token: "orange"), .coral)
        XCTAssertEqual(TBDLabelColor(token: " Coral "), .coral)
        XCTAssertEqual(TBDLabelColor(token: "yellow"), .amber)
        XCTAssertEqual(TBDLabelColor(token: "AMBER"), .amber)
        for color in [TBDLabelColor.green, .red, .purple, .blue] { XCTAssertEqual(TBDLabelColor(token: color.rawValue), color) }
        XCTAssertEqual(TBDLabelColor(token: nil), .automatic)
        XCTAssertEqual(TBDLabelColor(token: "pink"), .automatic)
        XCTAssertNil(TBDLabelColor.automatic.token)
        XCTAssertEqual(TBDLabelColor.purple.token, "purple")
        // The automatic color is a hash of the label id (FNV-1a over the UUID bytes), so it never changes.
        XCTAssertEqual(TBDLabelColor.automaticSlot(for: "0b1c6f7e-aaaa-4a3b-9c8d-000000000001", paletteCount: 6), 4)
        XCTAssertEqual(TBDLabelColor.automaticSlot(for: "0b1c6f7e-aaaa-4a3b-9c8d-000000000002", paletteCount: 6), 3)
        XCTAssertEqual(TBDLabelColor.automaticSlot(for: "0B1C6F7E-AAAA-4A3B-9C8D-000000000002", paletteCount: 6), 3, "upper case is the same id")
        XCTAssertEqual(TBDLabelColor.automaticSlot(for: "0b1c6f7e-aaaa-4a3b-9c8d-000000000002", paletteCount: 7), 6)
        XCTAssertEqual(TBDLabelColor.automaticSlot(for: "x", paletteCount: 0), 0)
    }

    // MARK: Storage

    func testMigrationFollowsKnowledgeAndCreatesTheTables() throws {
        let db = try TBDListeningDatabase(inMemory: ())
        let names = try db.writer.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
        let knowledge = try XCTUnwrap(names.firstIndex(of: "v6-knowledge"))
        XCTAssertEqual(Array(names[(knowledge + 1)...]), ["v7-favorites", "v7-meeting-classification", "v7-capture-notice"])
        let tables = try db.writer.read { try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('meetingLabel','transcriptionLabel','promptLabelPolicy') ORDER BY name") }
        XCTAssertEqual(tables, ["meetingLabel", "promptLabelPolicy", "transcriptionLabel"])
    }

    func testCreateRenameColorArchiveAndDelete() throws {
        let db = try library()
        let customer = try db.createMeetingLabel(name: "  Customer ")
        let internalLabel = try db.createMeetingLabel(name: "Internal", colorToken: "blue")
        XCTAssertEqual(customer.name, "Customer")
        XCTAssertEqual(customer.sortOrder, 0)
        XCTAssertEqual(internalLabel.sortOrder, 1)
        XCTAssertEqual(try db.meetingLabels().map(\.name), ["Customer", "Internal"])

        XCTAssertThrowsError(try db.createMeetingLabel(name: "customer")) { XCTAssertEqual($0 as? TBDLabelError, .duplicateName("customer")) }
        XCTAssertThrowsError(try db.createMeetingLabel(name: " ")) { XCTAssertEqual($0 as? TBDLabelError, .emptyName) }
        XCTAssertThrowsError(try db.renameMeetingLabel(id: internalLabel.id, to: "CUSTOMER")) { XCTAssertEqual($0 as? TBDLabelError, .duplicateName("CUSTOMER")) }
        XCTAssertThrowsError(try db.renameMeetingLabel(id: "missing", to: "Anything")) { XCTAssertEqual($0 as? TBDLabelError, .missingLabel) }

        try db.renameMeetingLabel(id: internalLabel.id, to: "  Team  ")
        try db.renameMeetingLabel(id: customer.id, to: "CUSTOMER")      // own name, other case: allowed
        try db.setMeetingLabelColor(id: customer.id, token: "coral")
        XCTAssertEqual(try db.meetingLabel(id: internalLabel.id)?.name, "Team")
        XCTAssertEqual(try db.meetingLabel(id: customer.id)?.name, "CUSTOMER")
        XCTAssertEqual(try db.meetingLabel(id: customer.id)?.colorToken, "coral")
        try db.setMeetingLabelColor(id: customer.id, token: nil)
        XCTAssertNil(try db.meetingLabel(id: customer.id)?.colorToken)

        try db.setMeetingLabelArchived(id: customer.id, isArchived: true)
        XCTAssertEqual(try db.meetingLabels().map(\.name), ["Team"])
        XCTAssertEqual(try db.meetingLabels(includeArchived: true).map(\.name), ["CUSTOMER", "Team"])
        XCTAssertThrowsError(try db.createMeetingLabel(name: "customer"), "an archived label still owns its name")
        try db.setMeetingLabelArchived(id: customer.id, isArchived: false)
        XCTAssertEqual(try db.meetingLabels().map(\.name), ["CUSTOMER", "Team"])

        try db.deleteMeetingLabel(id: internalLabel.id)
        XCTAssertNil(try db.meetingLabel(id: internalLabel.id))
    }

    func testAssignManyLabelsToATranscriptAndKeepArchivedOnes() throws {
        let db = try library()
        let item = try transcript(db, "Sync")
        let a = try db.createMeetingLabel(name: "Alpha")
        let b = try db.createMeetingLabel(name: "Beta")
        let c = try db.createMeetingLabel(name: "Gamma")

        try db.setLabels([c.id, a.id], for: item.id)
        XCTAssertEqual(try db.labels(for: item.id).map(\.name), ["Alpha", "Gamma"])
        XCTAssertEqual(try db.labelIDs(for: item.id), [a.id, c.id])
        try db.toggleLabel(b.id, for: item.id)
        try db.toggleLabel(a.id, for: item.id)
        XCTAssertEqual(try db.labels(for: item.id).map(\.name), ["Beta", "Gamma"])

        // Archiving keeps the label on the transcript but stops it being added elsewhere.
        try db.setMeetingLabelArchived(id: b.id, isArchived: true)
        XCTAssertEqual(try db.labels(for: item.id).map(\.name), ["Beta", "Gamma"])
        try db.setLabels([b.id, c.id, a.id], for: item.id)
        XCTAssertEqual(try db.labelIDs(for: item.id), [a.id, b.id, c.id])
        let other = try transcript(db, "Other")
        XCTAssertThrowsError(try db.setLabels([b.id], for: other.id)) { XCTAssertEqual($0 as? TBDLabelError, .unavailable([b.id])) }
        XCTAssertThrowsError(try db.setLabels([a.id, "ghost"], for: other.id)) { XCTAssertEqual($0 as? TBDLabelError, .unavailable(["ghost"])) }
        XCTAssertEqual(try db.labelIDs(for: other.id), [], "a refused change leaves the labels as they were")

        // Labels work for every source, not only meetings.
        let file = try transcript(db, "Recording", kind: .file)
        try db.setLabels([a.id], for: file.id)
        XCTAssertEqual(try db.labelIDs(for: file.id), [a.id])
        try db.setLabels([], for: item.id)
        XCTAssertEqual(try db.labelIDs(for: item.id), [])
    }

    func testDeleteIsRefusedWhileALabelIsInUse() throws {
        let db = try library()
        let item = try transcript(db, "Sync")
        let label = try db.createMeetingLabel(name: "Customer")
        try db.setLabels([label.id], for: item.id)
        XCTAssertEqual(try db.meetingLabelUseCounts(), [label.id: 1])
        XCTAssertThrowsError(try db.deleteMeetingLabel(id: label.id)) { XCTAssertEqual($0 as? TBDLabelError, .inUse) }
        XCTAssertNotNil(try db.meetingLabel(id: label.id))
        // Deleting the transcript frees the label.
        try db.deleteTranscription(id: item.id)
        XCTAssertEqual(try db.meetingLabelUseCounts(), [:])
        try db.deleteMeetingLabel(id: label.id)
        XCTAssertNil(try db.meetingLabel(id: label.id))
    }

    func testFilterMatchesAnySelectedLabel() throws {
        let db = try library()
        let one = try transcript(db, "One")
        let two = try transcript(db, "Two")
        let three = try transcript(db, "Three")
        _ = three
        let a = try db.createMeetingLabel(name: "Alpha")
        let b = try db.createMeetingLabel(name: "Beta")
        try db.setLabels([a.id, b.id], for: one.id)
        try db.setLabels([b.id], for: two.id)

        XCTAssertNil(try db.transcriptionIDs(withAnyLabel: []), "no label ticked means no filter")
        XCTAssertEqual(try db.transcriptionIDs(withAnyLabel: [a.id]), [one.id])
        XCTAssertEqual(try db.transcriptionIDs(withAnyLabel: [b.id]), [one.id, two.id])
        XCTAssertEqual(try db.transcriptionIDs(withAnyLabel: [a.id, b.id]), [one.id, two.id], "a transcript with both labels is listed once")
        XCTAssertEqual(try db.transcriptionIDs(withAnyLabel: ["ghost"]), [])
    }

    // MARK: Prompts aimed at labels

    private func prompt(name: String = "p", visible: Bool = true, autoRun: Bool = false, category: TBDPrompt.Category = .result) -> TBDPrompt {
        TBDPrompt(name: name, content: "c", category: category, isVisible: visible, isAutoRun: autoRun)
    }

    func testResolverFollowsTheV1Rules() {
        let p = prompt(autoRun: true)
        func rule(_ scope: TBDPromptLabelPolicy.ScopeKind, _ label: String? = nil, _ available: Bool) -> TBDPromptLabelPolicy {
            TBDPromptLabelPolicy(promptId: p.id, scopeKind: scope, labelId: label, isAvailable: available)
        }
        func r(_ labels: Set<String>, _ policies: [TBDPromptLabelPolicy], _ prompt: TBDPrompt? = nil, _ source: TBDSourceKind = .meeting) -> TBDPromptLabelResolver.Resolution {
            TBDPromptLabelResolver.resolve(prompt: prompt ?? p, source: source, labelIDs: labels, policies: policies)
        }

        XCTAssertEqual(r([], []), .init(isAvailable: true, isAutoRun: true, reason: .noLabelTargeting))
        XCTAssertEqual(r(["x"], [rule(.all, nil, false), rule(.label, "x", true)]), .init(isAvailable: true, isAutoRun: true, reason: .matchingLabelPolicy))
        XCTAssertEqual(r(["y"], [rule(.all, nil, false), rule(.label, "x", true)]), .init(isAvailable: false, isAutoRun: false, reason: .allLabelsPolicy))
        XCTAssertEqual(r([], [rule(.all, nil, false), rule(.label, "x", true)]), .init(isAvailable: false, isAutoRun: false, reason: .allLabelsPolicy))
        XCTAssertEqual(r(["x"], [rule(.all, nil, true), rule(.label, "x", false)]), .init(isAvailable: false, isAutoRun: false, reason: .matchingLabelPolicy))
        XCTAssertEqual(r(["x", "z"], [rule(.all, nil, false), rule(.label, "x", false), rule(.label, "z", true)]),
                       .init(isAvailable: true, isAutoRun: true, reason: .matchingLabelPolicy), "any available match offers the prompt")
        XCTAssertEqual(r(["y"], [rule(.label, "x", true)]), .init(isAvailable: false, isAutoRun: false, reason: .noMatchingLabelPolicy))
        XCTAssertEqual(r(["y"], [rule(.all, nil, true)]), .init(isAvailable: true, isAutoRun: true, reason: .allLabelsPolicy))

        // Auto-run also needs the prompt's own setting for the source.
        let manual = prompt(autoRun: false)
        XCTAssertEqual(r([], [], manual), .init(isAvailable: true, isAutoRun: false, reason: .noLabelTargeting))
        var meetingOnly = prompt(autoRun: true)
        meetingOnly.appliesToSources = [.meeting]
        XCTAssertTrue(r([], [], meetingOnly, .meeting).isAutoRun)
        XCTAssertFalse(r([], [], meetingOnly, .file).isAutoRun)
        XCTAssertTrue(r([], [], meetingOnly, .file).isAvailable)

        // Hidden prompts and Transforms are never offered.
        XCTAssertEqual(r([], [], prompt(visible: false, autoRun: true)), .init(isAvailable: false, isAutoRun: false, reason: .hidden))
        XCTAssertEqual(r([], [], prompt(autoRun: true, category: .transform)), .init(isAvailable: false, isAutoRun: false, reason: .notResultPrompt))
    }

    func testTargetingRulesRoundTrip() {
        XCTAssertEqual(TBDPromptLabelResolver.policies(promptId: "p", targeting: []), [])
        let rules = TBDPromptLabelResolver.policies(promptId: "p", targeting: ["b", "a"])
        XCTAssertEqual(rules.map(\.scopeKind), [.all, .label, .label])
        XCTAssertEqual(rules.map(\.labelId), [nil, "a", "b"])
        XCTAssertEqual(rules.map(\.isAvailable), [false, true, true])
        XCTAssertEqual(TBDPromptLabelResolver.targetLabelIDs(policies: rules), ["a", "b"])
        XCTAssertEqual(TBDPromptLabelResolver.targetLabelIDs(policies: []), [])
        XCTAssertEqual(TBDPromptLabelResolver.targetLabelIDs(policies: [TBDPromptLabelPolicy(promptId: "p", scopeKind: .all, isAvailable: true)]), [])
    }

    func testPromptsAimedAtLabelsAreOfferedAndAutoRunOnlyForThoseTranscripts() throws {
        let db = try library()
        let customer = try db.createMeetingLabel(name: "Customer")
        let other = try db.createMeetingLabel(name: "Internal")
        let everywhere = try db.savePrompt(TBDPrompt(name: "Recap", content: "Recap it.", isAutoRun: true))
        let targeted = try db.savePrompt(TBDPrompt(name: "Account notes", content: "Notes.", isAutoRun: true))
        try db.setTargetLabels([customer.id], promptId: targeted.id)
        XCTAssertEqual(try db.targetLabelIDs(promptId: targeted.id), [customer.id])
        XCTAssertEqual(try db.targetLabelIDs(promptId: everywhere.id), [])

        // Auto-run: a meeting without labels gets the prompts offered everywhere, the labelled one gets the targeted too.
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting, labelIDs: []).map(\.name), ["Summary", "Recap"])
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting, labelIDs: [other.id]).map(\.name), ["Summary", "Recap"])
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting, labelIDs: [customer.id]).map(\.name), ["Summary", "Recap", "Account notes"])
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting).map(\.name), ["Summary", "Recap", "Account notes"], "the label-less call keeps its earlier behavior")

        // The summary menu of one transcript.
        let item = try transcript(db, "Call")
        let all = ["Summary", "Action Items & Decisions", "Chapter Breakdown", "Study Guide", "Blog Post", "What Stood Out", "Recap"]
        XCTAssertEqual(try db.availableResultPrompts(for: item.id).map(\.name), all)
        try db.setLabels([customer.id], for: item.id)
        XCTAssertEqual(try db.availableResultPrompts(for: item.id).map(\.name), all + ["Account notes"])
        XCTAssertEqual(try db.availableResultPrompts(for: "missing"), [])

        // Aiming at no label offers it everywhere again.
        try db.setTargetLabels([], promptId: targeted.id)
        XCTAssertEqual(try db.autoRunPrompts(for: .meeting, labelIDs: []).map(\.name), ["Summary", "Recap", "Account notes"])
        XCTAssertEqual(try db.promptLabelPolicies(promptIds: [targeted.id]), [])
    }

    func testRulesGoWhenTheLabelIsDeleted() throws {
        let db = try library()
        let label = try db.createMeetingLabel(name: "Customer")
        let prompt = try db.savePrompt(TBDPrompt(name: "Account notes", content: "Notes."))
        try db.setTargetLabels([label.id], promptId: prompt.id)
        XCTAssertEqual(try db.promptLabelPolicies(promptIds: [prompt.id]).count, 2)
        try db.deleteMeetingLabel(id: label.id)
        XCTAssertEqual(try db.promptLabelPolicies(promptIds: [prompt.id]).map(\.scopeKind), [.all],
                       "only the 'not offered' fallback is left; re-aim or clear the prompt")
    }
}
