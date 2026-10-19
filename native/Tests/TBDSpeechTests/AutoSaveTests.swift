import XCTest
@testable import TBDSpeech

final class AutoSaveTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbd-autosave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suite = "tbd.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(title: String = "Standup", kind: TBDSourceKind = .meeting) -> TBDTranscription {
        var item = TBDTranscription(title: title, sourceKind: kind, status: .completed)
        item.createdAt = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        item.words = [
            TBDWord(text: "Hello", start: 0, end: 400, speaker: "S1"), TBDWord(text: "team.", start: 450, end: 900, speaker: "S1"),
            TBDWord(text: "Hi", start: 61_500, end: 61_800, speaker: "S2"), TBDWord(text: "there.", start: 61_850, end: 62_300, speaker: "S2"),
        ]
        item.rawText = "Hello team. Hi there."
        item.speakers = TBDTranscriptAssembler.speakers(in: item.words)
        item.segments = TBDTranscriptAssembler.segments(words: item.words)
        item.durationMs = 62_300
        return item
    }

    private func saver() -> TBDAutoSaver {
        TBDAutoSaver(preferences: TBDListeningPreferences(defaults: defaults), timeZone: TimeZone(identifier: "UTC")!)
    }

    private func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    private func enable(_ scope: TBDAutoSaveScope, format: TBDExportFormat = .md) {
        let config = TBDListeningPreferences(defaults: defaults).autoSave(scope)
        config.enabled = true
        config.format = format
        XCTAssertTrue(config.setFolder(dir))
    }

    // MARK: Names

    func testFileNameIsDateAndTitleWithTheFormatExtension() {
        let url = TBDAutoSaver.fileURL(for: sample(), format: .md, in: dir, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(url.lastPathComponent, "2023-11-14-221320-Standup.md")
        XCTAssertEqual(TBDAutoSaver.fileURL(for: sample(), format: .dapt, in: dir, timeZone: TimeZone(identifier: "UTC")!).lastPathComponent,
                       "2023-11-14-221320-Standup.dapt.xml")
        XCTAssertEqual(TBDAutoSaver.fileURL(for: sample(), format: .md, in: dir, timeZone: TimeZone(identifier: "Europe/Berlin")!).lastPathComponent,
                       "2023-11-14-231320-Standup.md", "the name uses local time")
    }

    func testTitleIsMadeSafeForAFileName() {
        XCTAssertEqual(TBDAutoSaver.sanitizedStem("Q3/Q4: plan\\v2"), "Q3 Q4  plan v2")
        XCTAssertEqual(TBDAutoSaver.sanitizedStem("  Roadmap sync  "), "Roadmap sync")
        XCTAssertEqual(TBDAutoSaver.sanitizedStem(""), "transcript")
        XCTAssertEqual(TBDAutoSaver.sanitizedStem(" / : "), "transcript")
    }

    func testTakenNamesGetACounter() {
        var taken: Set<String> = []
        func next() -> String {
            let url = TBDAutoSaver.fileURL(for: sample(), format: .txt, in: dir, timeZone: TimeZone(identifier: "UTC")!) { taken.contains($0.lastPathComponent) }
            taken.insert(url.lastPathComponent)
            return url.lastPathComponent
        }
        XCTAssertEqual([next(), next(), next()], ["2023-11-14-221320-Standup.txt", "2023-11-14-221320-Standup (1).txt", "2023-11-14-221320-Standup (2).txt"])
    }

    // MARK: Writing

    func testDisabledWritesNothing() throws {
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        XCTAssertTrue(config.setFolder(dir))
        XCTAssertFalse(config.enabled, "off by default")
        XCTAssertEqual(saver().saveIfEnabled(sample(kind: .file), scope: .transcription), .disabled)
        XCTAssertEqual(try files(), [])
    }

    func testEachFormatWritesTheExporterOutputToTheExpectedName() throws {
        let item = sample()
        for (format, name) in [(TBDExportFormat.txt, "txt"), (.md, "md"), (.srt, "srt"), (.vtt, "vtt"), (.json, "json"), (.dapt, "dapt.xml")] {
            let fresh = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
            config.enabled = true; config.format = format
            XCTAssertTrue(config.setFolder(fresh))
            let outcome = saver().saveIfEnabled(item, scope: .transcription)
            let target = fresh.appendingPathComponent("2023-11-14-221320-Standup.\(name)")
            guard case .saved(let written) = outcome else { XCTFail("not saved: \(outcome)"); continue }
            // The folder comes back from its bookmark, so /var may read /private/var.
            XCTAssertEqual(written.resolvingSymlinksInPath().path, target.resolvingSymlinksInPath().path, name)
            XCTAssertEqual(try Data(contentsOf: target), TBDExport.data(item, as: format), name)
        }
        let txt = try String(contentsOf: dir.appendingPathComponent("txt/2023-11-14-221320-Standup.txt"), encoding: .utf8)
        XCTAssertEqual(txt, "Speaker 1: Hello team.\n\nSpeaker 2: Hi there.\n")
        let vtt = try String(contentsOf: dir.appendingPathComponent("vtt/2023-11-14-221320-Standup.vtt"), encoding: .utf8)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n00:00:00.000 --> 00:00:00.900\n<v Speaker 1>Hello team.\n\n"), vtt)
    }

    func testSecondSaveOfTheSameTranscriptDoesNotOverwrite() throws {
        enable(.transcription, format: .txt)
        _ = saver().saveIfEnabled(sample(kind: .file), scope: .transcription)
        _ = saver().saveIfEnabled(sample(kind: .file), scope: .transcription)
        XCTAssertEqual(try files(), ["2023-11-14-221320-Standup (1).txt", "2023-11-14-221320-Standup.txt"])
    }

    func testScopesKeepSeparateSettings() throws {
        enable(.meeting, format: .srt)
        XCTAssertEqual(saver().saveIfEnabled(sample(kind: .file), scope: .transcription), .disabled)
        XCTAssertEqual(try files(), [])
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        XCTAssertEqual(config.format, .md, "default format")
        XCTAssertFalse(config.hasFolder)
        XCTAssertEqual(TBDListeningPreferences(defaults: defaults).autoSave(.meeting).format, .srt)
        defaults.set("docx", forKey: "tbd.listening.autoSaveFormat")
        XCTAssertEqual(config.format, .md, "a format v1 did not offer falls back")
    }

    func testMeetingOptionsLeaveOutTheirParts() throws {
        enable(.meeting, format: .md)
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.meeting)
        XCTAssertEqual(config.options, TBDExportOptions(), "all on by default")
        config.options = TBDExportOptions(includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: false)
        guard case .saved(let url) = saver().saveIfEnabled(sample(), scope: .meeting) else { return XCTFail("not saved") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Standup\n\n## Transcript\n\nHello team.\n\nHi there.\n\n")
        XCTAssertEqual(TBDListeningPreferences(defaults: defaults).autoSave(.transcription).options, .default, "transcriptions always export everything")
    }

    func testPlainTextWithoutSpeakerLabels() {
        let item = sample()
        XCTAssertEqual(TBDExport.render(item, as: .txt, options: TBDExportOptions(includeSpeakerLabels: false)), "Hello team.\n\nHi there.\n")
        XCTAssertEqual(TBDExport.render(item, as: .txt), "Speaker 1: Hello team.\n\nSpeaker 2: Hi there.\n")
    }

    // MARK: Errors are shown, not silent

    func testNoFolderChosenIsAPlainError() throws {
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        config.enabled = true
        XCTAssertEqual(saver().saveIfEnabled(sample(kind: .file), scope: .transcription),
                       .failed("Auto-save is on for transcripts, but no folder is chosen. Choose a folder in Settings."))
        let meeting = TBDListeningPreferences(defaults: defaults).autoSave(.meeting)
        meeting.enabled = true
        XCTAssertEqual(saver().saveIfEnabled(sample(), scope: .meeting),
                       .failed("Auto-save is on for meetings, but no folder is chosen. Choose a folder in Settings."))
    }

    func testMissingFolderIsAPlainErrorAndNothingIsCreated() throws {
        let gone = dir.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        config.enabled = true
        XCTAssertTrue(config.setFolder(gone))
        try FileManager.default.removeItem(at: gone)
        guard case .failed(let message) = saver().saveIfEnabled(sample(kind: .file), scope: .transcription) else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("The auto-save folder"), message)
        XCTAssertTrue(message.hasSuffix("is not available. Choose another folder in Settings.") || message.hasSuffix("are not available. Choose another folder in Settings."), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), "a missing folder is not silently recreated")
        XCTAssertEqual(try files(), [])
    }

    func testAFolderThatCannotBeWrittenIsAPlainError() throws {
        let locked = dir.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        config.enabled = true
        XCTAssertTrue(config.setFolder(locked))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        guard case .failed(let message) = saver().saveIfEnabled(sample(kind: .file), scope: .transcription) else { return XCTFail("expected a failure") }
        XCTAssertTrue(message.hasPrefix("Could not save the transcript to \"Locked\": "), message)
    }

    // MARK: Folder helpers

    func testDefaultFoldersAndKeepingAChosenFolder() {
        XCTAssertTrue(TBDAutoSaveConfig.defaultFolder(for: .transcription).path.hasSuffix("/Documents/TBD Desktop/Listening/Transcriptions"))
        XCTAssertTrue(TBDAutoSaveConfig.defaultFolder(for: .meeting).path.hasSuffix("/Documents/TBD Desktop/Listening/Meetings"))
        let config = TBDListeningPreferences(defaults: defaults).autoSave(.transcription)
        XCTAssertTrue(config.setFolder(dir))
        XCTAssertEqual(config.ensureFolderConfigured()?.standardizedFileURL.path, dir.standardizedFileURL.path, "a chosen folder is kept")
        XCTAssertEqual(config.resolvedFolder()?.standardizedFileURL.path, dir.standardizedFileURL.path)
    }

    // MARK: Notices

    func testNoticeTextIsExact() {
        XCTAssertEqual(TBDCompletionNotice.single(enabled: true, name: "Interview", wordCount: 1),
                       TBDCompletionNotice.Content(title: "Interview", body: "Transcription complete \u{00B7} 1 word"))
        XCTAssertEqual(TBDCompletionNotice.single(enabled: true, name: "Interview", wordCount: 250)?.body, "Transcription complete \u{00B7} 250 words")
        XCTAssertNil(TBDCompletionNotice.single(enabled: false, name: "Interview", wordCount: 250))
        XCTAssertEqual(TBDCompletionNotice.batch(enabled: true, completed: 3, failed: 0),
                       TBDCompletionNotice.Content(title: "Transcriptions complete", body: "3 files transcribed"))
        XCTAssertEqual(TBDCompletionNotice.batch(enabled: true, completed: 1, failed: 0)?.body, "1 file transcribed")
        XCTAssertEqual(TBDCompletionNotice.batch(enabled: true, completed: 2, failed: 1),
                       TBDCompletionNotice.Content(title: "Transcriptions finished with errors", body: "2 transcribed \u{00B7} 1 failed"))
        XCTAssertNil(TBDCompletionNotice.batch(enabled: false, completed: 2, failed: 1))
        XCTAssertEqual(TBDCompletionNotice.meetingReady(enabled: true, title: "Roadmap Sync", wordCount: 1200),
                       TBDCompletionNotice.Content(title: "Roadmap Sync", body: "Meeting transcript ready \u{00B7} 1200 words"))
        XCTAssertNil(TBDCompletionNotice.meetingReady(enabled: false, title: "Roadmap Sync", wordCount: 1200))
    }
}
