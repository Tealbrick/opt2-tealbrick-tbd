import Foundation
import TBDModels

/// Which kind of transcript an auto-save rule covers (v1 `AutoSaveScope`).
public enum TBDAutoSaveScope: String, Sendable, CaseIterable {
    case transcription, meeting

    var enabledKey: String { self == .transcription ? "tbd.listening.autoSaveTranscripts" : "tbd.listening.autoSaveMeetings" }
    var formatKey: String { self == .transcription ? "tbd.listening.autoSaveFormat" : "tbd.listening.meetingAutoSaveFormat" }
    var folderKey: String { self == .transcription ? "tbd.listening.autoSaveFolderBookmark" : "tbd.listening.meetingAutoSaveFolderBookmark" }
    static let includeTimestampsKey = "tbd.listening.meetingAutoSaveIncludeTimestamps"
    static let includeSpeakerLabelsKey = "tbd.listening.meetingAutoSaveIncludeSpeakerLabels"
    static let includeMetadataKey = "tbd.listening.meetingAutoSaveIncludeMetadata"

    /// Word used in messages.
    public var noun: String { self == .transcription ? "transcript" : "meeting" }
    public var defaultFolderName: String { self == .transcription ? "Transcriptions" : "Meetings" }
}

/// The settings of one auto-save rule, stored in the host's UserDefaults. Off by default; format Markdown.
public struct TBDAutoSaveConfig: @unchecked Sendable {
    let defaults: UserDefaults
    public let scope: TBDAutoSaveScope

    /// The six formats v1 offered.
    public static let formats: [TBDExportFormat] = [.txt, .md, .srt, .vtt, .dapt, .json]

    public var enabled: Bool {
        get { defaults.bool(forKey: scope.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: scope.enabledKey) }
    }
    public var format: TBDExportFormat {
        get {
            let stored = defaults.string(forKey: scope.formatKey).flatMap(TBDExportFormat.init(rawValue:)) ?? .md
            return Self.formats.contains(stored) ? stored : .md
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: scope.formatKey) }
    }
    /// Meeting rules only; transcriptions always export everything.
    public var options: TBDExportOptions {
        get {
            guard scope == .meeting else { return .default }
            func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
            return TBDExportOptions(includeTimestamps: flag(TBDAutoSaveScope.includeTimestampsKey),
                                    includeSpeakerLabels: flag(TBDAutoSaveScope.includeSpeakerLabelsKey),
                                    includeMetadata: flag(TBDAutoSaveScope.includeMetadataKey))
        }
        nonmutating set {
            defaults.set(newValue.includeTimestamps, forKey: TBDAutoSaveScope.includeTimestampsKey)
            defaults.set(newValue.includeSpeakerLabels, forKey: TBDAutoSaveScope.includeSpeakerLabelsKey)
            defaults.set(newValue.includeMetadata, forKey: TBDAutoSaveScope.includeMetadataKey)
        }
    }

    // MARK: Folder (stored as a bookmark, so a moved or renamed folder is still found)

    public var hasFolder: Bool { defaults.data(forKey: scope.folderKey) != nil }

    /// The chosen folder, or nil when none is stored or the bookmark no longer resolves (deleted, drive gone).
    /// A stale bookmark is refreshed.
    public func resolvedFolder() -> URL? {
        guard let data = defaults.data(forKey: scope.folderKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: scope.folderKey) }
        return url
    }

    /// Stores `url` as the folder. Returns false when macOS cannot make a bookmark of it.
    @discardableResult
    public func setFolder(_ url: URL) -> Bool {
        guard let data = try? url.bookmarkData() else { return false }
        defaults.set(data, forKey: scope.folderKey)
        return true
    }

    /// `~/Documents/TBD Desktop/Listening/Transcriptions` or `.../Meetings` (TBDIdentity.documentsFolder).
    public static func defaultFolder(for scope: TBDAutoSaveScope) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent(TBDIdentity.documentsFolder + "/Listening/\(scope.defaultFolderName)", isDirectory: true)
    }

    /// Creates the default folder and stores it. Returns nil when that fails.
    @discardableResult
    public func resetFolderToDefault() -> URL? {
        let url = Self.defaultFolder(for: scope)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil, setFolder(url) else { return nil }
        return url
    }

    /// Keeps a chosen folder, even one that does not resolve now (a disconnected drive); stores the default only when none is set.
    @discardableResult
    public func ensureFolderConfigured() -> URL? {
        hasFolder ? resolvedFolder() : resetFolderToDefault()
    }
}

/// Writes a finished transcript to the chosen folder (v1 `AutoSaveService`). Never throws: the result says
/// what happened so the caller can show a failure without failing the save that triggered it.
public struct TBDAutoSaver: Sendable {
    public enum Outcome: Equatable, Sendable {
        case disabled
        case saved(URL)
        /// Plain-language reason, safe to show.
        case failed(String)
    }

    public let preferences: TBDListeningPreferences
    public var timeZone: TimeZone

    public init(preferences: TBDListeningPreferences = TBDListeningPreferences(), timeZone: TimeZone = .current) {
        self.preferences = preferences
        self.timeZone = timeZone
    }

    @discardableResult
    public func saveIfEnabled(_ item: TBDTranscription, summaries: [TBDSummary] = [], scope: TBDAutoSaveScope) -> Outcome {
        let config = preferences.autoSave(scope)
        guard config.enabled else { return .disabled }
        guard config.hasFolder else {
            return .failed("Auto-save is on for \(scope.noun)s, but no folder is chosen. Choose a folder in Settings.")
        }
        guard let folder = config.resolvedFolder() else {
            return .failed("The auto-save folder for \(scope.noun)s is not available. Choose another folder in Settings.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed("The auto-save folder \"\(folder.lastPathComponent)\" is not available. Choose another folder in Settings.")
        }
        let format = config.format
        let target = Self.fileURL(for: item, format: format, in: folder, timeZone: timeZone)
        do {
            try TBDExport.data(item, as: format, summaries: summaries, options: config.options).write(to: target, options: .atomic)
            return .saved(target)
        } catch {
            return .failed("Could not save the \(scope.noun) to \"\(folder.lastPathComponent)\": \(error.localizedDescription)")
        }
    }

    /// `yyyy-MM-dd-HHmmss-<title>.<ext>`; a taken name gets " (1)", " (2)" and so on.
    public static func fileURL(for item: TBDTranscription, format: TBDExportFormat, in folder: URL, timeZone: TimeZone = .current,
                               exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let base = "\(formatter.string(from: item.createdAt))-\(sanitizedStem(item.title))"
        var url = folder.appendingPathComponent("\(base).\(format.fileExtension)")
        var counter = 1
        while exists(url) {
            url = folder.appendingPathComponent("\(base) (\(counter)).\(format.fileExtension)")
            counter += 1
        }
        return url
    }

    /// Path separators, colons and NUL become spaces; an empty result is "transcript" (v1 `sanitizedExportStem`).
    public static func sanitizedStem(_ title: String) -> String {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "/:\\\0"))
        let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? "transcript" : joined
    }
}

/// Title and body of the "transcription finished" chime and banner (v1 `TranscriptionCompletionNotifier`).
/// Each builder returns nil when its Settings switch is off.
public enum TBDCompletionNotice {
    public struct Content: Equatable, Sendable {
        public let title: String
        public let body: String
        public init(title: String, body: String) { self.title = title; self.body = body }
    }

    public static func single(enabled: Bool, name: String, wordCount: Int) -> Content? {
        enabled ? Content(title: name, body: "Transcription complete \u{00B7} \(words(wordCount))") : nil
    }

    /// One notice when a batch drains, never one per file.
    public static func batch(enabled: Bool, completed: Int, failed: Int) -> Content? {
        guard enabled else { return nil }
        if failed == 0 { return Content(title: "Transcriptions complete", body: "\(files(completed)) transcribed") }
        return Content(title: "Transcriptions finished with errors", body: "\(completed) transcribed \u{00B7} \(failed) failed")
    }

    public static func meetingReady(enabled: Bool, title: String, wordCount: Int) -> Content? {
        enabled ? Content(title: title, body: "Meeting transcript ready \u{00B7} \(words(wordCount))") : nil
    }

    static func words(_ count: Int) -> String { "\(count) \(count == 1 ? "word" : "words")" }
    static func files(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
}
