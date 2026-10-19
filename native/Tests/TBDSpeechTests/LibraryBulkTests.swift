import GRDB
import XCTest
@testable import TBDSpeech

/// WP4 library: favorites, selection mode and bulk delete / remove audio, export options and bulk export.
final class LibraryBulkTests: XCTestCase {
    private var dir: URL!
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-library-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "tbd.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_767_000_000 + seconds) }

    private func item(_ title: String, kind: TBDSourceKind = .file, status: TBDTranscriptionStatus = .completed, text: String = "",
                      at seconds: TimeInterval = 0, favorite: Bool = false) -> TBDTranscription {
        var item = TBDTranscription(title: title, sourceKind: kind, status: status)
        item.createdAt = at(seconds)
        item.rawText = text
        item.isFavorite = favorite
        return item
    }

    /// Two speakers, 1:02:05 long (the ExportTests sample).
    private func sample(title: String = "Standup") -> TBDTranscription {
        var item = TBDTranscription(title: title, sourceKind: .meeting, status: .completed)
        item.words = [
            TBDWord(text: "Hello", start: 0, end: 400, speaker: "S1"), TBDWord(text: "team.", start: 450, end: 900, speaker: "S1"),
            TBDWord(text: "Hi", start: 61_500, end: 61_800, speaker: "S2"), TBDWord(text: "there.", start: 61_850, end: 3_725_250, speaker: "S2"),
        ]
        item.rawText = "Hello team. Hi there."
        item.speakers = TBDTranscriptAssembler.speakers(in: item.words)
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        item.durationMs = 3_725_250
        return item
    }

    private func memoryDatabase() throws -> TBDListeningDatabase { try TBDListeningDatabase(inMemory: ()) }

    // MARK: Migration and favorites

    func testMigrationAddsFavoriteColumnAfterKnowledgeAndKeepsOldRows() throws {
        let names = TBDListeningDatabase.migrator.migrations
        let knowledge = try XCTUnwrap(names.firstIndex(of: "v6-knowledge"))
        XCTAssertEqual(names[knowledge + 1], "v7-favorites")

        let queue = try DatabaseQueue()
        try TBDListeningDatabase.migrator.migrate(queue, upTo: "v6-knowledge")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO transcription (id, createdAt, updatedAt, title, sourceKind, status, rawText)
                VALUES ('old', ?, ?, 'Budget review', 'meeting', 'completed', 'quarterly numbers')
                """, arguments: [self.at(0), self.at(0)])
        }
        try TBDListeningDatabase.migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT isFavorite FROM transcription WHERE id = 'old'"), false)
            XCTAssertEqual(try TBDTranscription.fetchOne(db, key: "old")?.title, "Budget review")
            XCTAssertEqual(try TBDTranscription.fetchOne(db, key: "old")?.isFavorite, false)
        }
    }

    func testStarringKeepsFullTextSearchExact() throws {
        let db = try memoryDatabase()
        let a = item("Budget review", text: "quarterly numbers", at: 10)
        let b = item("Garden plan", text: "tomatoes and numbers", at: 20)
        try db.save(a); try db.save(b)
        XCTAssertEqual(try db.transcriptions(matching: "numbers").map(\.title), ["Garden plan", "Budget review"])

        try db.setFavorite(id: a.id, true)
        XCTAssertEqual(try db.transcription(id: a.id)?.isFavorite, true)
        // The update trigger re-indexes the row once: one hit each, no duplicate or lost rows.
        XCTAssertEqual(try db.transcriptions(matching: "numbers").map(\.title), ["Garden plan", "Budget review"])
        XCTAssertEqual(try db.transcriptions(matching: "quarterly").map(\.title), ["Budget review"])
        XCTAssertEqual(try db.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transcription_ft WHERE transcription_ft MATCH 'numbers'") }, 2)

        try db.setFavorite(id: a.id, false)
        XCTAssertEqual(try db.transcription(id: a.id)?.isFavorite, false)
        try db.deleteTranscription(id: a.id)
        XCTAssertEqual(try db.transcriptions(matching: "quarterly").map(\.title), [])
        XCTAssertEqual(try db.transcriptions(matching: "numbers").map(\.title), ["Garden plan"])
    }

    func testFavoritesFilterWithKindSearchAndSort() throws {
        let db = try memoryDatabase()
        let ids = [
            item("Charlie sync", kind: .meeting, text: "roadmap", at: 30, favorite: true),
            item("Alpha call", kind: .meeting, text: "roadmap", at: 10, favorite: true),
            item("Bravo notes", kind: .meeting, text: "roadmap", at: 20),
            item("Delta file", kind: .file, text: "roadmap", at: 40, favorite: true),
        ]
        for entry in ids { try db.save(entry) }

        XCTAssertEqual(try db.transcriptions(favoritesOnly: true, sort: .newest).map(\.title), ["Delta file", "Charlie sync", "Alpha call"])
        XCTAssertEqual(try db.transcriptions(favoritesOnly: true, sort: .oldest).map(\.title), ["Alpha call", "Charlie sync", "Delta file"])
        XCTAssertEqual(try db.transcriptions(favoritesOnly: true, sort: .title).map(\.title), ["Alpha call", "Charlie sync", "Delta file"])
        XCTAssertEqual(try db.transcriptions(kind: .meeting, favoritesOnly: true, sort: .newest).map(\.title), ["Charlie sync", "Alpha call"])
        XCTAssertEqual(try db.transcriptions(kind: .meeting, matching: "roadmap", favoritesOnly: true, sort: .oldest).map(\.title), ["Alpha call", "Charlie sync"])
        XCTAssertEqual(try db.transcriptions(matching: "roadmap", favoritesOnly: true).map(\.title), ["Delta file", "Charlie sync", "Alpha call"])
        XCTAssertEqual(try db.transcriptions(kind: .meeting, sort: .newest).count, 3, "no filter lists everything")
    }

    func testSavingAnOlderCopyKeepsTheStar() throws {
        let db = try memoryDatabase()
        var stale = item("Interview", status: .processing)
        try db.save(stale)
        try db.setFavorite(id: stale.id, true)     // starred while it was still transcribing
        stale.status = .completed
        stale.rawText = "done"
        try db.save(stale)                          // the finished transcription is saved from the older copy
        let stored = try XCTUnwrap(db.transcription(id: stale.id))
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.isFavorite, true)

        // A new item keeps the star it is created with.
        let fresh = item("Imported", favorite: true)
        try db.save(fresh)
        XCTAssertEqual(try db.transcription(id: fresh.id)?.isFavorite, true)
    }

    // MARK: Selection

    func testSelectionRules() {
        var selection = TBDLibrarySelection()
        XCTAssertFalse(selection.isActive)
        selection.begin(startingWith: "b")
        XCTAssertTrue(selection.isActive)
        XCTAssertEqual(selection.ids, ["b"])
        selection.toggle("a"); selection.toggle("b")
        XCTAssertEqual(selection.ids, ["a"])
        XCTAssertFalse(selection.areAllSelected(["a", "b", "c"]))
        selection.selectAll(["a", "b", "c"])
        XCTAssertTrue(selection.areAllSelected(["a", "b", "c"]))
        XCTAssertTrue(selection.areAllSelected([]), "nothing listed counts as all selected")
        selection.prune(to: ["b", "c", "z"])
        XCTAssertEqual(selection.ids, ["b", "c"])
        selection.clear()
        XCTAssertEqual(selection.ids, [])
        XCTAssertTrue(selection.isActive, "clear keeps selection mode")

        selection.selectAll(["a", "b", "c"])
        selection.keepFailed(["b", "gone"], visible: ["b", "c"])
        XCTAssertEqual(selection.ids, ["b"])
        selection.keepFailed([], visible: ["b"])
        XCTAssertEqual(selection.ids, ["b"], "no failures changes nothing")
        selection.exit()
        XCTAssertFalse(selection.isActive)
        XCTAssertEqual(selection.ids, [])
    }

    func testSelectedRowsKeepListOrder() {
        let rows = [item("One"), item("Two"), item("Three")]
        var selection = TBDLibrarySelection()
        selection.begin(startingWith: rows[2].id)
        selection.toggle(rows[0].id)
        XCTAssertEqual(selection.selected(in: rows).map(\.title), ["One", "Three"])
        XCTAssertEqual(selection.count, 2)
    }

    // MARK: Confirmation texts

    func testDeleteTextsForFilesMeetingsAndMixes() {
        let file = item("Talk"), meeting = item("Sync", kind: .meeting), unfinished = item("Failed sync", kind: .meeting, status: .failed)

        let files = TBDBulkDeletePlan([file, file])
        XCTAssertEqual(files.title, "Delete Items?")
        XCTAssertEqual(files.confirmTitle, "Delete Items")
        XCTAssertEqual(files.message, "Delete 2 items? This permanently deletes the Library rows and app-owned files. Original local source files are not removed.")

        let one = TBDBulkDeletePlan([meeting])
        XCTAssertEqual(one.title, "Delete Meeting?")
        XCTAssertEqual(one.confirmTitle, "Delete Meeting")
        XCTAssertEqual(one.message, "This permanently deletes 1 meeting, including its transcript and saved audio. Notes, AI results, and chats for this meeting are also deleted if they exist.")

        let many = TBDBulkDeletePlan([meeting, unfinished])
        XCTAssertEqual(many.title, "Delete Meetings?")
        XCTAssertEqual(many.confirmTitle, "Delete Meetings")
        XCTAssertEqual(many.message, "At least one selected meeting hasn't been transcribed yet — deleting it makes that permanent. This permanently deletes 2 meetings, including transcripts and saved audio. Notes, AI results, and chats for those meetings are also deleted if they exist.")

        let mixed = TBDBulkDeletePlan([file, meeting, meeting])
        XCTAssertEqual(mixed.title, "Delete Items?")
        XCTAssertEqual(mixed.message, "This permanently deletes 3 items, including 2 meetings. Meeting transcripts, saved audio, notes, AI results, and chats are removed if they exist. Original local source files are not removed.")

        let single = TBDBulkDeletePlan.single(file)
        XCTAssertEqual(single.title, "Delete Transcription?")
        XCTAssertEqual(single.confirm, "Delete")
        XCTAssertEqual(single.message, "“Talk” will be permanently deleted. Original local source files are not removed.")
        XCTAssertEqual(TBDBulkDeletePlan.single(meeting).title, "Delete Meeting?")
    }

    func testRemoveAudioTextsAndFailureMessages() {
        let meeting = item("Sync", kind: .meeting)
        let plan = TBDBulkAudioPlan([meeting, meeting], skipped: 1, surface: "Meetings")
        XCTAssertEqual(plan.message, "3 selected meetings. This permanently deletes saved audio from 2 meetings. The meetings stay in Meetings with their transcripts. Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available. 1 selected meeting cannot have its audio removed right now, so it will be skipped.")
        XCTAssertEqual(TBDBulkAudioPlan([meeting], skipped: 0, surface: "Library").message,
                       "This permanently deletes saved audio from 1 meeting. The meeting stays in Library with its transcript. Notes, AI results, and chats stay too if they exist. Playback and re-transcription will no longer be available.")

        var outcome = TBDLibraryOutcome()
        XCTAssertNil(outcome.deleteMessage())
        XCTAssertNil(outcome.audioMessage(skipped: 0))
        outcome.succeeded = ["a", "b"]
        outcome.failed = [.init(id: "c", title: "Sync", reason: "It is still processing. Wait for it to finish.")]
        XCTAssertEqual(outcome.deleteMessage(), "Deleted 2 items. 1 could not be deleted. Sync: It is still processing. Wait for it to finish.")
        XCTAssertEqual(outcome.audioMessage(skipped: 2),
                       "Deleted audio for 2 meetings. 1 meeting audio file could not be deleted. 2 selected items were skipped. Sync: It is still processing. Wait for it to finish.")
        XCTAssertEqual(outcome.failedIDs, ["c"])
        outcome.succeeded = []
        XCTAssertEqual(outcome.deleteMessage(), "1 item could not be deleted. Sync: It is still processing. Wait for it to finish.")
    }

    // MARK: Bulk delete and remove audio (files)

    private struct Library {
        let db: TBDListeningDatabase
        let root: URL
        let meetings: URL
        var sweeper: TBDRetentionSweeper { TBDRetentionSweeper(database: db, managedRoot: root, meetingsRoot: meetings) }
    }

    private func library() throws -> Library {
        let root = dir.appendingPathComponent("Listening", isDirectory: true)
        let meetings = root.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        return Library(db: try memoryDatabase(), root: root, meetings: meetings)
    }

    @discardableResult
    private func write(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: url)
        return url.path
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testBulkDeleteRemovesRowsAndManagedFilesOnly() throws {
        let lib = try library()
        // Meeting with a folder: audio and notes file go with it.
        var meeting = item("Sync", kind: .meeting)
        let folder = lib.meetings.appendingPathComponent("sync-1", isDirectory: true)
        meeting.audioPaths = [try write(folder.appendingPathComponent("microphone.wav"))]
        try write(folder.appendingPathComponent("notes.txt"))
        // File transcript with kept audio in the managed folder, and a person's own source file outside it.
        var file = item("Talk")
        let kept = lib.root.appendingPathComponent("Downloads/talk.wav")
        file.audioPaths = [try write(kept)]
        let own = dir.appendingPathComponent("Music/own.m4a")
        try write(own)
        file.sourcePath = own.path
        // Meeting whose audio sits loose in the managed root: only the file may go, never the root folder.
        var loose = item("Loose", kind: .meeting)
        let looseFile = lib.root.appendingPathComponent("loose.wav")
        loose.audioPaths = [try write(looseFile)]
        let processing = item("Running", kind: .file, status: .processing)
        for entry in [meeting, file, loose, processing] { try lib.db.save(entry) }

        let outcome = lib.sweeper.deleteFromLibrary(ids: [meeting.id, file.id, loose.id, processing.id, "missing-id"])
        XCTAssertEqual(outcome.succeeded, [meeting.id, file.id, loose.id, "missing-id"])
        XCTAssertEqual(outcome.failed, [.init(id: processing.id, title: "Running", reason: "It is still processing. Wait for it to finish.")])
        XCTAssertFalse(exists(folder), "meeting folder removed")
        XCTAssertFalse(exists(kept))
        XCTAssertFalse(exists(looseFile))
        XCTAssertTrue(exists(lib.root), "the managed root is never removed")
        XCTAssertTrue(exists(lib.meetings))
        XCTAssertTrue(exists(own), "a person's own file stays")
        XCTAssertEqual(try lib.db.transcriptions(sort: .title).map(\.title), ["Running"])
    }

    func testRemoveAudioKeepsMeetingNotesAndFolder() throws {
        let lib = try library()
        var meeting = item("Sync", kind: .meeting, text: "decisions")
        let folder = lib.meetings.appendingPathComponent("sync-1", isDirectory: true)
        let audio = folder.appendingPathComponent("microphone.wav")
        meeting.audioPaths = [try write(audio)]
        let notes = folder.appendingPathComponent("meeting.json")
        try write(notes)
        meeting.userNotes = "my notes"
        var running = item("Live", kind: .meeting, status: .processing)
        running.audioPaths = [try write(lib.meetings.appendingPathComponent("live/microphone.wav"))]
        let file = item("Talk")
        for entry in [meeting, running, file] { try lib.db.save(entry) }
        try lib.db.setFavorite(id: meeting.id, true)

        XCTAssertTrue(TBDRetentionSweeper.hasRemovableAudio(meeting))
        XCTAssertFalse(TBDRetentionSweeper.hasRemovableAudio(running), "still processing")
        XCTAssertFalse(TBDRetentionSweeper.hasRemovableAudio(file), "not a meeting")

        let outcome = lib.sweeper.removeAudio(ids: [meeting.id, running.id, file.id])
        XCTAssertEqual(outcome.succeeded, [meeting.id])
        XCTAssertEqual(outcome.failed.map { [$0.title, $0.reason] },
                       [["Live", "It is still processing. Wait for it to finish."], ["Talk", "Only meetings have saved audio."]])
        XCTAssertFalse(exists(audio))
        XCTAssertTrue(exists(notes), "the meeting folder stays")
        let stored = try XCTUnwrap(lib.db.transcription(id: meeting.id))
        XCTAssertEqual(stored.audioPaths, [])
        XCTAssertEqual(stored.userNotes, "my notes")
        XCTAssertEqual(stored.rawText, "decisions")
        XCTAssertTrue(stored.isFavorite)
        XCTAssertFalse(TBDRetentionSweeper.hasRemovableAudio(stored), "nothing left to remove")
        XCTAssertEqual(try lib.db.transcription(id: running.id)?.audioPaths.count, 1)
    }

    func testRemovableAudioNeedsAFileOnDisk() {
        var meeting = item("Sync", kind: .meeting)
        meeting.audioPaths = ["/gone/a.wav", "/here/b.wav"]
        XCTAssertTrue(TBDRetentionSweeper.hasRemovableAudio(meeting, exists: { $0 == "/here/b.wav" }))
        XCTAssertFalse(TBDRetentionSweeper.hasRemovableAudio(meeting, exists: { _ in false }))
        meeting.audioPaths = []
        XCTAssertFalse(TBDRetentionSweeper.hasRemovableAudio(meeting, exists: { _ in true }))
    }

    // MARK: Export options

    func testFormatPickerNamesAndOptionSupport() {
        XCTAssertEqual(TBDExportFormat.pickerOrder, [.txt, .md, .srt, .vtt, .dapt, .json, .pdf, .docx])
        XCTAssertEqual(Set(TBDExportFormat.pickerOrder), Set(TBDExportFormat.allCases))
        XCTAssertEqual(TBDExportFormat.pickerOrder.map(\.shortName), ["Text", "Markdown", "SRT", "VTT", "DAPT", "JSON", "PDF", "DOCX"])
        XCTAssertEqual(TBDExportFormat.allCases.filter(\.supportsOptions), [.txt, .md])
    }

    func testOptionsResolveAgainstWhatTheTranscriptHas() {
        let timed = sample()
        var plain = item("Note", kind: .voiceNote, text: "Just text")
        plain.durationMs = 2000
        let all = TBDExportOptions()

        XCTAssertEqual(all.resolved(for: timed, format: .md), all)
        XCTAssertEqual(all.resolved(for: plain, format: .md), TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: true))
        XCTAssertEqual(TBDExportOptions(includeTimestamps: true, includeSpeakerLabels: true, includeMetadata: false).resolved(for: plain, format: .txt),
                       TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false))
        // Words but no speakers: timestamps stay, labels go.
        var untitledSpeakers = timed
        untitledSpeakers.speakers = []
        XCTAssertEqual(all.resolved(for: untitledSpeakers, format: .txt), TBDExportOptions(includeTimestamps: true, includeSpeakerLabels: false, includeMetadata: true))
        // Formats without options are written with the defaults whatever the switches say.
        let off = TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false)
        for format in [TBDExportFormat.srt, .vtt, .dapt, .json, .pdf, .docx] {
            XCTAssertEqual(off.resolved(for: timed, format: format), .default, format.rawValue)
        }
        XCTAssertTrue(timed.canExportTimestamps)
        XCTAssertTrue(timed.canExportSpeakerLabels)
        XCTAssertFalse(plain.canExportTimestamps)
        XCTAssertFalse(plain.canExportSpeakerLabels)
    }

    private func text(_ item: TBDTranscription, _ options: TBDExportOptions) -> String {
        String(decoding: TBDExport.libraryData(item, as: .txt, options: options), as: UTF8.self)
    }

    func testPlainTextFollowsTheOptions() {
        let talk = sample()
        XCTAssertEqual(text(talk, TBDExportOptions()),
                       "Standup\nDuration: 1:02:05\n\nSpeaker 1:\n[0:00] Hello team.\n\nSpeaker 2:\n[1:01] Hi there.\n")
        XCTAssertEqual(text(talk, TBDExportOptions(includeSpeakerLabels: false)),
                       "Standup\nDuration: 1:02:05\n\n[0:00] Hello team.\n\n[1:01] Hi there.\n")
        XCTAssertEqual(text(talk, TBDExportOptions(includeTimestamps: false)),
                       "Standup\nDuration: 1:02:05\n\nSpeaker 1:\nHello team.\n\nSpeaker 2:\nHi there.\n")
        XCTAssertEqual(text(talk, TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false)),
                       "Standup\nDuration: 1:02:05\n\nHello team. Hi there.\n")
        XCTAssertEqual(text(talk, TBDExportOptions(includeTimestamps: true, includeSpeakerLabels: true, includeMetadata: false)),
                       "Speaker 1:\n[0:00] Hello team.\n\nSpeaker 2:\n[1:01] Hi there.\n")
        XCTAssertEqual(text(talk, TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false)),
                       "Hello team. Hi there.\n")
    }

    func testPlainTextNamesTheSpeakerOnlyWhereItChangesAndFlagsUnassigned() {
        var talk = item("Call", kind: .meeting)
        talk.speakers = [TBDSpeaker(id: "S1", label: "Ana")]
        talk.segments = [TBDSegment(start: 0, end: 400, text: "One.", speaker: "S1"),
                         TBDSegment(start: 5_000, end: 5_400, text: "Two.", speaker: "S1"),
                         TBDSegment(start: 9_000, end: 9_400, text: "Three.")]
        talk.durationMs = 0
        XCTAssertEqual(text(talk, TBDExportOptions(includeMetadata: false)), "Ana:\n[0:00] One.\n\n[0:05] Two.\n\nUnassigned:\n[0:09] Three.\n")
    }

    func testPlainTextWithoutTimingOrSpeakersDropsTheseOptions() {
        var note = item("Note", kind: .voiceNote, text: "Just text")
        note.durationMs = 2000
        XCTAssertEqual(text(note, TBDExportOptions()), "Note\nDuration: 0:02\n\nJust text\n")
        XCTAssertEqual(text(note, TBDExportOptions(includeMetadata: false)), "Just text\n")
    }

    func testMarkdownHonoursResolvedOptionsAndOtherFormatsIgnoreThem() throws {
        var note = item("Note", kind: .voiceNote, text: "Just text")
        note.durationMs = 2000
        let md = String(decoding: TBDExport.libraryData(note, as: .md), as: UTF8.self)
        XCTAssertTrue(md.hasPrefix("# Note\n\n- Source: Voice note\n"), md)
        XCTAssertTrue(md.hasSuffix("## Transcript\n\nJust text\n\n"), md)
        XCTAssertFalse(md.contains("`0:00`"), "no stamp for a transcript without timing")
        XCTAssertTrue(String(decoding: TBDExport.data(note, as: .md), as: UTF8.self).contains("`0:00`"), "the plain export still stamps")

        let talk = sample()
        let off = TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false)
        let stripped = String(decoding: TBDExport.libraryData(talk, as: .md, options: off), as: UTF8.self)
        XCTAssertEqual(stripped, "# Standup\n\n## Transcript\n\nHello team.\n\nHi there.\n\n")

        for format in [TBDExportFormat.srt, .vtt, .dapt, .json, .docx] {
            XCTAssertEqual(TBDExport.libraryData(talk, as: format, options: off), TBDExport.data(talk, as: format), format.rawValue)
        }
        // PDF files carry a creation time, so compare what does not vary: it is a PDF of the same layout size.
        let pdf = TBDExport.libraryData(talk, as: .pdf, options: off)
        XCTAssertEqual(Array(pdf.prefix(5)), Array("%PDF-".utf8))
        XCTAssertEqual(pdf.count, TBDExport.data(talk, as: .pdf).count)
    }

    // MARK: File names

    func testStemAndNextAvailableName() {
        XCTAssertEqual(TBDExportFiles.stem(item("Q3 / plan: draft")), "Q3   plan  draft")
        XCTAssertEqual(TBDExportFiles.stem(item("  ")), "transcript")
        let folder = URL(fileURLWithPath: "/exports", isDirectory: true)
        var taken: Set<String> = []
        func next(_ format: TBDExportFormat = .md) -> String {
            let url = TBDExportFiles.nextAvailableURL(in: folder, stem: "Standup", format: format, exists: { taken.contains($0.lastPathComponent) })
            return url.lastPathComponent
        }
        XCTAssertEqual(next(), "Standup.md")
        taken.insert("Standup.md")
        XCTAssertEqual(next(), "Standup (1).md")
        taken.insert("Standup (1).md")
        XCTAssertEqual(next(), "Standup (2).md")
        XCTAssertEqual(next(.dapt), "Standup.dapt.xml", "another format is another name")
        taken.insert("Standup.dapt.xml")
        XCTAssertEqual(next(.dapt), "Standup (1).dapt.xml")
    }

    // MARK: Settings

    func testBulkExportSettingsDefaultsAndPersistence() {
        let settings = TBDListeningPreferences(defaults: defaults).libraryExport
        XCTAssertEqual(settings.format, .txt)
        XCTAssertEqual(settings.options, TBDExportOptions())
        XCTAssertNil(defaults.object(forKey: "tbd.listening.libraryBulkExportFormat"), "reading writes nothing")

        settings.format = .vtt
        settings.options = TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: true, includeMetadata: false)
        let again = TBDListeningPreferences(defaults: defaults).libraryExport
        XCTAssertEqual(again.format, .vtt)
        XCTAssertEqual(again.options, TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: true, includeMetadata: false))
        XCTAssertEqual(defaults.string(forKey: "tbd.listening.libraryBulkExportFormat"), "vtt")
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.libraryBulkExportIncludeTimestamps") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.libraryBulkExportIncludeSpeakerLabels") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "tbd.listening.libraryBulkExportIncludeMetadata") as? Bool, false)

        defaults.set("rtf", forKey: "tbd.listening.libraryBulkExportFormat")
        XCTAssertEqual(again.format, .txt, "an unknown stored format falls back to Text")
    }

    // MARK: Bulk export

    func testBulkExportWritesOneFilePerItemWithUniqueNames() async throws {
        let target = dir.appendingPathComponent("out", isDirectory: true)   // does not exist yet
        let one = sample(title: "Standup"), two = sample(title: "Standup"), three = sample(title: "Other / notes")
        let result = try await TBDBulkExport.run([one, two, three], format: .md, options: TBDExportOptions(includeMetadata: false), directory: target)

        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["Standup.md", "Standup (1).md", "Other   notes.md"])
        XCTAssertEqual(result.requestedCount, 3)
        XCTAssertEqual(result.exportedCount, 3)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertTrue(result.isCompleteSuccess)
        XCTAssertEqual(result.title, "Exported 3 Markdown files")
        XCTAssertEqual(result.failureLines, [])
        let written = try String(contentsOf: target.appendingPathComponent("Standup.md"), encoding: .utf8)
        XCTAssertEqual(written, String(decoding: TBDExport.libraryData(one, as: .md, options: TBDExportOptions(includeMetadata: false)), as: UTF8.self))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).sorted(), ["Other   notes.md", "Standup (1).md", "Standup.md"])

        // A second run into the same folder never overwrites.
        let again = try await TBDBulkExport.run([one], format: .md, options: .default, directory: target)
        XCTAssertEqual(again.exportedURLs.map(\.lastPathComponent), ["Standup (2).md"])
        XCTAssertEqual(again.title, "Exported 1 Markdown file")
    }

    func testBulkExportUsesPreparedTranscriptAndSummaries() async throws {
        let target = dir.appendingPathComponent("out")
        var shown = sample(title: "Edited")
        shown.words[0].text = "Howdy"
        shown.segments[0].text = "Howdy team."
        let summary = TBDSummary(transcriptionId: shown.id, kind: .summary, prompt: "", content: "Short.")
        let prepared = shown
        let result = try await TBDBulkExport.run([sample(title: "Standup")], format: .md, options: .default, directory: target) { _ in (prepared, [summary]) }
        let file = try String(contentsOf: try XCTUnwrap(result.exportedURLs.first), encoding: .utf8)
        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["Edited.md"], "named from the prepared transcript")
        XCTAssertTrue(file.contains("## Summary\n\nShort."), file)
        XCTAssertTrue(file.contains("Howdy team."), file)
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "disk is full" }
    }

    func testBulkExportCountsAndListsFailuresAndKeepsGoing() async throws {
        let target = dir.appendingPathComponent("out")
        let result = try await TBDBulkExport.run([sample(title: "A"), sample(title: "Bad"), sample(title: "C")], format: .txt, options: .default, directory: target) { source in
            if source.title == "Bad" { throw Boom() }
            return (source, [])
        }
        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["A.txt", "C.txt"])
        XCTAssertEqual(result.failures, [.init(title: "Bad", message: "disk is full")])
        XCTAssertEqual(result.failureLines, ["Bad: disk is full"])
        XCTAssertEqual(result.firstError, "disk is full")
        XCTAssertFalse(result.isCompleteSuccess)
        XCTAssertEqual(result.title, "Exported 2 of 3")
    }

    func testBulkExportThatWritesNothingRemovesItsNewFolderButNotAnOldOne() async throws {
        let fresh = dir.appendingPathComponent("fresh")
        let failed = try await TBDBulkExport.run([sample()], format: .txt, options: .default, directory: fresh) { _ in throw Boom() }
        XCTAssertEqual(failed.exportedCount, 0)
        XCTAssertEqual(failed.title, "No files exported")
        XCTAssertEqual(failed.failureLines, ["Standup: disk is full"])
        XCTAssertFalse(exists(fresh), "an empty folder this run created is removed")

        let old = dir.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        _ = try await TBDBulkExport.run([sample()], format: .txt, options: .default, directory: old) { _ in throw Boom() }
        XCTAssertTrue(exists(old), "a folder that was there stays")
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func hit() { lock.lock(); count += 1; lock.unlock() }
        var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testCancelledBulkExportRemovesWhatItWrote() async throws {
        let fresh = dir.appendingPathComponent("cancel-new")
        let old = dir.appendingPathComponent("cancel-old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let keep = old.appendingPathComponent("mine.txt")
        try Data("mine".utf8).write(to: keep)

        for target in [fresh, old] {
            let gate = Gate()
            let task = Task {
                try await TBDBulkExport.run([sample(title: "A"), sample(title: "B"), sample(title: "C")], format: .txt, options: .default, directory: target) { source in
                    gate.hit()
                    // The second item waits until the test cancels the run.
                    if source.title == "B" { while !Task.isCancelled { usleep(1_000) } }
                    return (source, [])
                }
            }
            while gate.hits < 2 { try await Task.sleep(for: .milliseconds(5)) }
            task.cancel()
            do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
            XCTAssertEqual(gate.hits, 2, "no item after the cancel is prepared")
        }
        XCTAssertFalse(exists(fresh), "files and the new folder are gone")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: old.path), ["mine.txt"], "only this run's files are removed")
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "mine")
    }
}
