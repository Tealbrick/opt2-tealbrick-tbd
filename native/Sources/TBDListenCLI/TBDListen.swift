import ArgumentParser
import Foundation
import TBDModels
import TBDSpeech

/// `tbd-listen`: local access to the TBD Listening library for scripts and TBD's default agent.
@main
struct TBDListen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tbd-listen",
        abstract: "Transcribe audio and query the TBD Listen library.",
        version: TBDSpeechVersion.string,
        subcommands: [Transcribe.self, History.self, Search.self, Show.self, Meetings.self, Export.self, Delete.self, Stats.self,
                      Engines.self, Models.self, Vocabulary.self, Snippets.self, Podcasts.self, Config.self, YtDlp.self]
    )
}

/// Preferences shared with the TBD app (engines, languages, Listening settings).
let appPreferences = TBDListeningPreferences(defaults: UserDefaults(suiteName: TBDIdentity.liveBundleID) ?? .standard)

func openLibrary(readOnly: Bool = true) throws -> TBDListeningDatabase {
    if !readOnly { return try TBDListeningDatabase() }
    do { return try TBDListeningDatabase(readOnly: true) } catch {
        throw ValidationError("No Listen library at \(TBDListeningPaths.database.path). Use TBD once or run `tbd-listen transcribe`.")
    }
}

func output(_ text: String) { FileHandle.standardOutput.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8)) }
func status(_ text: String) { FileHandle.standardError.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8)) }
func outputJSON<T: Encodable>(_ value: T) { output(TBDListenJSON.encode(value)) }

func shortDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

/// Progress on stderr as "Stage 42%".
@Sendable func reportProgress(_ stage: String, _ fraction: Double) {
    FileHandle.standardError.write(Data("\r\(stage) \(Int(fraction * 100))%   ".utf8))
}

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent dictations.")
    @Option(help: "Maximum number of dictations.") var limit = 20
    @Option(help: "Only dictations containing these words.") var query: String?
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let items = try openLibrary().dictations(limit: max(1, limit), matching: query)
        if json { outputJSON(items.map(TBDListenJSON.Dictation.init)); return }
        if items.isEmpty { output("No dictations."); return }
        for item in items {
            output("\(item.id.prefix(8))  \(shortDate(item.createdAt))  \(item.wordCount) words  \(item.targetApp ?? "-")\n  \(item.text)")
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search of transcripts.")
    @Argument(help: "Search words (prefix match).") var query: [String]
    @Option(help: "Maximum number of results.") var limit = 20
    @Option(help: "Only one kind: file, url, meeting or voiceNote.") var kind: String?
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let sourceKind = try kind.map { value -> TBDSourceKind in
            guard let parsed = TBDSourceKind(rawValue: value) else { throw ValidationError("Unknown kind \(value).") }
            return parsed
        }
        let items = try openLibrary().transcriptions(limit: max(1, limit), kind: sourceKind, matching: query.joined(separator: " "))
        printItems(items, json: json)
    }
}

struct Meetings: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recorded meetings.")
    @Option(help: "Maximum number of meetings.") var limit = 20
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        printItems(try openLibrary().transcriptions(limit: max(1, limit), kind: .meeting), json: json)
    }
}

func printItems(_ items: [TBDTranscription], json: Bool) {
    if json { outputJSON(items.map(TBDListenJSON.Item.init)); return }
    if items.isEmpty { output("No results."); return }
    for item in items {
        output("\(item.id.prefix(8))  \(shortDate(item.createdAt))  \(item.sourceKind.rawValue)  \(TBDExport.clock(item.durationMs))  \(item.title)")
    }
}

/// Text formats print to stdout; DOCX and PDF are binary and only `export -o` writes them.
func parseFormat(_ value: String, allowBinary: Bool = false) throws -> TBDExportFormat {
    guard let format = TBDExportFormat(rawValue: value.lowercased()) else {
        throw ValidationError("Unknown format \(value). Use txt, md, srt, vtt, json or dapt\(allowBinary ? ", docx or pdf" : "").")
    }
    if format.isBinary, !allowBinary {
        throw ValidationError("\(format.rawValue) is binary. Use `tbd-listen export <id> --format \(format.rawValue) -o <file>`.")
    }
    return format
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print one transcript (id or unique id prefix).")
    @Argument(help: "Transcript id or unique prefix.") var id: String
    @Option(help: "Format: txt, md, srt, vtt, json or dapt.") var format = "txt"

    func run() throws {
        let format = try parseFormat(format)
        let library = try openLibrary()
        guard let item = try library.transcription(id: id) else { throw ValidationError("No transcript matches \(id).") }
        output(TBDExport.render(item, as: format, summaries: (try? library.summaries(for: item.id)) ?? []))
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a transcript to a file or stdout.")
    @Argument(help: "Transcript id or unique prefix.") var id: String
    @Option(help: "Format: txt, md, srt, vtt, json, dapt, or (with -o) docx or pdf.") var format = "txt"
    @Option(name: [.short, .long], help: "File to write (default: stdout). A directory gets <title>.<format>.") var output: String?

    func run() throws {
        let format = try parseFormat(format, allowBinary: output != nil)
        let library = try openLibrary()
        guard let item = try library.transcription(id: id) else { throw ValidationError("No transcript matches \(id).") }
        if format == .srt || format == .vtt, item.words.isEmpty {
            status("Note: this transcript has no word timestamps; subtitles use one cue per segment.")
        }
        let summaries = (try? library.summaries(for: item.id)) ?? []
        guard let output else { TBDListenCLI.output(TBDExport.render(item, as: format, summaries: summaries)); return }
        var destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let safe = item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            destination.appendPathComponent("\(safe).\(format.fileExtension)")
        }
        try TBDExport.data(item, as: format, summaries: summaries).write(to: destination, options: .atomic)
        status("Wrote \(destination.path)")
    }
}

struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a transcript (or dictation) and its stored audio.")
    @Argument(help: "Transcript id or unique prefix (dictations: full id).") var id: String
    @Flag(help: "Delete a dictation instead of a transcript.") var dictation = false
    @Flag(help: "Confirm the deletion (required).") var yes = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        guard yes else { throw ValidationError("Deleting cannot be undone. Add --yes to confirm.") }
    }

    func run() throws {
        let library = try openLibrary(readOnly: false)
        var removed: [String] = []
        let resolvedID: String
        if dictation {
            guard let item = try library.dictations(limit: 100_000).first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
                throw ValidationError("No dictation matches \(id).")
            }
            resolvedID = item.id
            if let path = item.audioPath, Self.removePrivateFile(path) { removed.append(path) }
            try library.deleteDictation(id: item.id)
        } else {
            guard let item = try library.transcription(id: id) else { throw ValidationError("No transcript matches \(id).") }
            resolvedID = item.id
            for path in item.audioPaths where Self.removePrivateFile(path) { removed.append(path) }
            try library.deleteTranscription(id: item.id)
        }
        if json { outputJSON(TBDListenJSON.Deleted(id: resolvedID, kind: dictation ? "dictation" : "transcription", deleted: true, removedFiles: removed)) }
        else { output("Deleted \(resolvedID)" + (removed.isEmpty ? "" : " and \(removed.count) audio file(s)")) }
    }

    /// Removes a file only when it lies inside the Listening folder (never the user's own source files).
    static func removePrivateFile(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = TBDListeningPaths.root.standardizedFileURL.path + "/"
        guard file.hasPrefix(root), FileManager.default.fileExists(atPath: file) else { return false }
        return (try? FileManager.default.removeItem(atPath: file)) != nil
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Library and dictation statistics.")
    @Flag(help: "Print JSON.") var json = false

    func run() throws {
        let library = try openLibrary()
        let stats = TBDListenJSON.Stats(dictation: try library.dictationStats(), transcriptions: try library.transcriptions(limit: 1_000_000),
                                        modelsBytes: TBDModelManager().totalBytes, storageBytes: TBDListeningPaths.diskUsage(of: TBDListeningPaths.root))
        if json { outputJSON(stats); return }
        output("""
        Dictations: \(stats.dictations) (\(stats.dictationsToday) today), \(stats.dictationWords) words, \(TBDExport.clock(stats.dictationDurationMs)) spoken, \(stats.wordsPerMinute) wpm
        Transcripts: \(stats.transcriptions) (\(TBDSourceKind.allCases.map { "\($0.label.lowercased()) \(stats.transcriptionsByKind[$0.rawValue] ?? 0)" }.joined(separator: ", "))), \(TBDExport.clock(stats.transcriptionDurationMs)) of audio
        Storage: \(stats.storageBytes.tbdByteString) (models \(stats.modelsBytes.tbdByteString))
        """)
    }
}
