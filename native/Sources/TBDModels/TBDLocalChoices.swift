import Foundation

/// The person's standing choices for TBD's agent's LOCAL actions on this Mac (dev.17, C280 C13 local part): "Always allow" and
/// "Never allow" for shell commands, file writes and web requests. They live in the Chat helper's `local-consent.json` (the same for
/// every workspace) and show in Settings › Access. The app only decides what to say; the helper decides what a choice covers.
/// Choices for connected accounts are in Settings › Connectors (`TBDConnectorChoice`).

/// One remembered local choice. The helper's rule key says what it covers: `shell:<exact command>`, `write:<folder>`, `web:<host>`,
/// `websearch`.
public struct TBDLocalChoice: Equatable, Identifiable, Sendable {
    public enum Decision: String, Equatable, Sendable { case always, never }
    public enum Kind: Equatable, Sendable { case shell, write, web, search }

    public var key: String
    public var decision: Decision

    public init(key: String, decision: Decision) {
        self.key = key; self.decision = decision
    }

    /// nil when the value is not the helper's shape or the key is none of the four kinds.
    public init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any], let key = o["key"] as? String, let raw = o["decision"] as? String,
              let decision = Decision(rawValue: raw), Self.kind(of: key) != nil else { return nil }
        self.init(key: key, decision: decision)
    }

    public var id: String { key }

    public static func kind(of key: String) -> Kind? {
        if key == "websearch" { return .search }
        if key.hasPrefix("shell:"), key.count > 6 { return .shell }
        if key.hasPrefix("write:/"), key.count > 7 { return .write }
        if key.hasPrefix("web:"), key.count > 4 { return .web }
        return nil
    }

    public var kind: Kind { Self.kind(of: key) ?? .shell }

    /// The longest text of one choice in the list; a longer one ends with "…".
    public static let displayMax = 200

    /// "Always allow · Run `npm test`", "Never allow · Write in ~/Projects/x", "Always allow · Fetch from example.com",
    /// "Always allow · Search the web". The home folder shows as "~". Characters that change how a line reads (bidirectional and
    /// control characters) are removed and line breaks show as "⏎".
    public func text(home: String = NSHomeDirectory()) -> String {
        let lead = decision == .always ? "Always allow" : "Never allow"
        switch kind {
        case .shell:
            return "\(lead) · Run `\(Self.shown(String(key.dropFirst(6))))`"
        case .write:
            return "\(lead) · Write in \(Self.shown(Self.abbreviated(String(key.dropFirst(6)), home: home)))"
        case .web:
            return "\(lead) · Fetch from \(Self.shown(String(key.dropFirst(4))))"
        case .search:
            return "\(lead) · Search the web"
        }
    }

    static func abbreviated(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func shown(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let c = scalar.value
            let bidi = (0x202A...0x202E).contains(c) || (0x2066...0x2069).contains(c) || c == 0x200E || c == 0x200F || c == 0x061C
            if bidi { continue }
            if c == 0x0A { out += " ⏎ "; continue }
            if c == 0x09 { out += " "; continue }
            if c < 0x20 || (0x7F...0x9F).contains(c) { continue }
            out.unicodeScalars.append(scalar)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.count > displayMax ? String(trimmed.prefix(displayMax)) + "…" : trimmed
    }

    /// The helper's list (`[{key, decision, at}]`); off-shape rows are dropped. The helper's order stays (newest first).
    public static func list(helperValue: Any?) -> [TBDLocalChoice] {
        (helperValue as? [Any] ?? []).compactMap { TBDLocalChoice(helperValue: $0) }
    }
}

/// The helper's answer to `localConsentList` / `localConsentRevoke`: `{ choices: [...], unreadable: Bool }`.
public struct TBDLocalChoices: Equatable, Sendable {
    public var choices: [TBDLocalChoice]
    public var unreadable: Bool

    public init(choices: [TBDLocalChoice] = [], unreadable: Bool = false) {
        self.choices = choices; self.unreadable = unreadable
    }

    public init(helperValue: Any?) {
        if let object = helperValue as? [String: Any] {
            self.init(choices: TBDLocalChoice.list(helperValue: object["choices"]), unreadable: object["unreadable"] as? Bool ?? false)
        } else {
            self.init(choices: TBDLocalChoice.list(helperValue: helperValue))
        }
    }

    // Words of the Settings › Access section.
    public static let title = "Your choices for TBD's agent on this Mac"
    public static let note = "These are TBD's own permissions on this Mac. They are not Rules rules (that needs Rules)."
    public static let connectorsLine = "Choices for connected accounts are in Settings › Connectors."
    public static let emptyLine = "No remembered choices yet. When TBD's agent asks to run a command, change a file or use the web, you can choose Always allow or Never allow."
    public static let failedLine = "TBD could not read your choices for this Mac."
    public static let unreadableLine = "TBD could not read your choices for this Mac. It kept a copy."
    public static let removeFailedLine = "TBD could not forget that choice. Try again."

    /// The notice for a list that may not be whole (shares `TBDChoicesIssue` with the Connectors choices; its own words).
    public static func line(_ issue: TBDChoicesIssue) -> String {
        issue == .failed ? failedLine : unreadableLine
    }
}
