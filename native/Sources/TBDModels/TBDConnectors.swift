import Foundation

/// Connectors (C280 C11, DESIGN-CONNECTORS §1, §3, §4, §10): pure rules for Settings › Connectors. The reads are the Chat
/// helper's (`connectAccounts`: TBD's own agent through the local relay; `connectConsentList` / `connectConsentRevoke`: the
/// person's remembered choices, a local file). The app only decides what to say and wires the links. TBD never connects,
/// shares or changes an account here: that is Connect's job; nothing here is a credential.

// MARK: - Accounts

/// The access TBD's agent has with one account (Connect manifest enum), in the words of C276. Never "Update" alone: a
/// grant that updates also creates, because Connect classes every non-read tool as create + update.
public enum TBDConnectorAccess: String, Equatable, Sendable {
    case read
    case readUpdate = "read_update"
    case readUpdateDelete = "read_update_delete"

    public var words: String {
        switch self {
        case .read: return "Read"
        case .readUpdate: return "Read + create + update"
        case .readUpdateDelete: return "Full (+ delete)"
        }
    }
}

/// `as_me`: the owner's own account; `as_itself`: an account TBD's agent acts as itself.
public enum TBDConnectorKind: String, Equatable, Sendable {
    case asMe = "as_me"
    case asItself = "as_itself"

    public var words: String { self == .asMe ? "as you" : "as TBD" }
}

public struct TBDConnectorAccount: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var service: String
    public var kind: TBDConnectorKind
    public var access: TBDConnectorAccess

    public init(id: String, label: String, service: String, kind: TBDConnectorKind, access: TBDConnectorAccess) {
        self.id = id; self.label = label; self.service = service; self.kind = kind; self.access = access
    }

    /// One account as the helper reduces it; nil for anything off-shape (never shown).
    public init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any],
              let id = o["id"] as? String, !id.isEmpty,
              let label = o["label"] as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let service = o["service"] as? String, !service.isEmpty,
              let kindRaw = o["kind"] as? String, let kind = TBDConnectorKind(rawValue: kindRaw),
              let accessRaw = o["access"] as? String, let access = TBDConnectorAccess(rawValue: accessRaw) else { return nil }
        self.init(id: id, label: label, service: service, kind: kind, access: access)
    }

    /// The service as a name: "gmail" gives "Gmail", "googlecalendar" "Google Calendar".
    public var serviceName: String { TBDConnectors.serviceName(service) }
}

/// The helper's answer to `connectAccounts`.
public struct TBDConnectorAccounts: Equatable, Sendable {
    public var available: Bool
    public var reason: String?
    public var accounts: [TBDConnectorAccount]

    public init(available: Bool, reason: String? = nil, accounts: [TBDConnectorAccount] = []) {
        self.available = available; self.reason = reason; self.accounts = accounts
    }

    /// nil when the value is not the helper's shape (the caller treats that as a failed check).
    public init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any], let available = o["available"] as? Bool else { return nil }
        self.init(available: available, reason: o["reason"] as? String,
                  accounts: (o["accounts"] as? [Any] ?? []).compactMap { TBDConnectorAccount(helperValue: $0) })
    }
}

// MARK: - Remembered choices

/// One of the person's remembered choices for TBD's agent ("Always allow" / "Never allow" per account and tool).
public struct TBDConnectorChoice: Equatable, Identifiable, Sendable {
    public enum Decision: String, Equatable, Sendable { case always, never }

    public var account: String
    public var tool: String
    public var decision: Decision

    public init(account: String, tool: String, decision: Decision) {
        self.account = account; self.tool = tool; self.decision = decision
    }

    public init?(helperValue: Any?) {
        guard let o = helperValue as? [String: Any], let account = o["account"] as? String, let tool = o["tool"] as? String,
              !tool.isEmpty, let raw = o["decision"] as? String, let decision = Decision(rawValue: raw) else { return nil }
        self.init(account: account, tool: tool, decision: decision)
    }

    public var id: String { "\(account)\u{1F}\(tool)" }

    /// "Always allow · GMAIL_SEND_EMAIL · Work inbox". The account the agent did not name reads "default account".
    public var text: String {
        let who = account.isEmpty || account == "default" ? "default account" : account
        return "\(decision == .always ? "Always allow" : "Never allow") · \(tool) · \(who)"
    }

    /// The helper's list (`[{account, tool, decision, at}]`); off-shape rows are dropped. Newest choices keep the helper's order.
    public static func list(helperValue: Any?) -> [TBDConnectorChoice] {
        (helperValue as? [Any] ?? []).compactMap { TBDConnectorChoice(helperValue: $0) }
    }
}

// MARK: - The gate

/// What the last accounts check said.
public enum TBDConnectorsProbe: Equatable, Sendable {
    case unanswered
    case available
    /// The relay lists no Connect access for TBD's agent (the helper's sentence).
    case unavailable(String)
    case failed(String)
}

/// What Settings › Connectors shows above the lists, and what button goes with it.
public enum TBDConnectorsGate: Equatable, Sendable {
    /// Nobody is signed in to Portal.
    case signedOut
    /// Not answered yet, or the plan is not known and nothing proved a grant. Never a lock (C282).
    case checking
    /// Paid for and granted: the accounts show.
    case active
    /// Connect is paid for but not running in this workspace.
    case install
    /// Connect is not paid for.
    case locked
    /// TBD's agent is not connected to the workspace.
    case notConnected
    /// Connected, but the owner gave TBD's agent no Connect access: the helper's sentence.
    case noGrant(String)
    /// The check failed (timeout, pause...): the person-facing sentence.
    case failed(String)

    public enum Action: Equatable, Sendable { case none, openPortal, connectAgent, signIn }

    /// The line for every gate except `.active`; nil when the accounts show.
    public var message: String? {
        switch self {
        case .active: return nil
        case .signedOut: return TBDConnectors.signedOutLine
        case .checking: return TBDConnectors.checkingLine
        case .install: return TBDConnectors.installLine
        case .locked: return TBDConnectors.lockedLine
        case .notConnected: return TBDConnectors.notConnectedLine
        case .noGrant(let sentence), .failed(let sentence): return sentence
        }
    }

    public var action: Action {
        switch self {
        case .signedOut: return .signIn
        case .install, .noGrant: return .openPortal
        case .notConnected: return .connectAgent
        case .active, .checking, .locked, .failed: return .none
        }
    }
}

public enum TBDConnectors {
    public static let signedOutLine = "Sign in to Teal Brick to see which accounts TBD's agent may use."
    public static let checkingLine = "Checking Connect…"
    public static let installLine = "Connect is paid for. Install it in Portal."
    public static let lockedLine = "Connectors: available with Connect."
    public static let notConnectedLine = "Connect TBD's agent to your workspace first."

    public static let accountsTitle = "Accounts TBD's agent may use"
    public static let emptyAccountsLine = "No account is shared with TBD's agent yet. Share accounts in Connect."
    public static let readOnlyHint = "TBD can read with these accounts. To let TBD send, give it 'Read + create + update' in Portal and in Connect."
    public static let choicesTitle = "Your choices for TBD's agent"
    public static let choicesNote = "These are TBD's own permissions on this Mac. They are not Rules rules (that needs Rules)."
    public static let noChoicesLine = "No remembered choices."

    /// The gate, from the plan (`connect`), the agent connection and the last accounts check. Table:
    /// - locked / install: that line, no helper call is needed.
    /// - unlocked or unknown: not connected → connect first; connected → checking until the check answers, then the list
    ///   (available), the helper's sentence (no grant) or the failure sentence. An unknown plan never locks (C282): it is
    ///   asked like a paid one, and a working grant through the relay is proof that Connect is active. Until the first answer
    ///   the store keeps `.checking` ("Checking Connect…").
    public static func decide(access: TBDAppAccess, agentConnected: Bool, probe: TBDConnectorsProbe) -> TBDConnectorsGate {
        switch access {
        case .locked: return .locked
        case .install: return .install
        case .unlocked, .unknown:
            guard agentConnected else { return .notConnected }
            switch probe {
            case .unanswered: return .checking
            case .available: return .active
            case .unavailable(let sentence): return .noGrant(sentence)
            case .failed(let sentence): return .failed(sentence)
            }
        }
    }

    /// Every listed account is Read only: say how to let TBD send (C276 words). Not for an empty list.
    public static func showsReadOnlyHint(_ accounts: [TBDConnectorAccount]) -> Bool {
        !accounts.isEmpty && accounts.allSatisfy { $0.access == .read }
    }

    // MARK: Links

    /// The Portal launcher link into Connect for the active workspace (Portal does the launch session; TBD never does):
    /// `<portal>/w/<ws>/open?product=connect&path=/configure#agents` (Manage in Connect) or `…&path=/` (Connect a new
    /// account). nil without an http(s) Portal address or a workspace.
    public static func connectLink(issuer: String, workspace: String, newAccount: Bool) -> URL? {
        guard let base = portalBase(issuer), !workspace.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let ws = workspace.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let head = "\(base)/w/\(ws)/open?product=connect&path="
        return URL(string: newAccount ? "\(head)/" : "\(head)/configure#agents")
    }

    /// The person's own Portal (the active profile's issuer); the public Portal when no profile is loaded yet.
    public static func portalURL(issuer: String) -> URL {
        if let base = portalBase(issuer), let url = URL(string: base) { return url }
        return URL(string: "https://portal.tealbrick.com")!
    }

    private static func portalBase(_ issuer: String) -> String? {
        let trimmed = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        var base = trimmed
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    // MARK: Names

    private static let knownServices: [String: String] = [
        "github": "GitHub", "gitlab": "GitLab", "googlecalendar": "Google Calendar", "googledrive": "Google Drive",
        "googlesheets": "Google Sheets", "googledocs": "Google Docs", "googlemeet": "Google Meet", "linkedin": "LinkedIn",
        "hubspot": "HubSpot", "whatsapp": "WhatsApp", "youtube": "YouTube", "onedrive": "OneDrive", "outlook": "Outlook",
        "clickup": "ClickUp", "airtable": "Airtable", "zoho": "Zoho",
    ]

    /// "gmail" → "Gmail", "google_calendar" → "Google Calendar".
    public static func serviceName(_ service: String) -> String {
        let key = service.lowercased()
        if let known = knownServices[key] { return known }
        let words = key.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? service : name
    }
}
