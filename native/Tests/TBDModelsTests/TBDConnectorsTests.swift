import XCTest
@testable import TBDModels

/// Connectors (C280 C11): the gate table, the access words, the Read-only hint, the Portal links and the helper shapes.
final class TBDConnectorsTests: XCTestCase {
    // MARK: Gate (DESIGN-CONNECTORS §1, C282)

    func testGateDecisionTable() {
        let answers: [(String, TBDConnectorsProbe)] = [
            ("unanswered", .unanswered), ("available", .available), ("noGrant", .unavailable("no grant")), ("failed", .failed("slow")),
        ]
        for connected in [false, true] {
            for (_, probe) in answers {
                // Not paid for / not installed: that line, whatever else is true.
                XCTAssertEqual(TBDConnectors.decide(access: .locked, agentConnected: connected, probe: probe), .locked)
                XCTAssertEqual(TBDConnectors.decide(access: .install, agentConnected: connected, probe: probe), .install)
                // Unlocked and unknown are asked the same way: an unknown plan never locks.
                for access in [TBDAppAccess.unlocked, .unknown] {
                    let gate = TBDConnectors.decide(access: access, agentConnected: connected, probe: probe)
                    if !connected {
                        XCTAssertEqual(gate, .notConnected, "\(access) not connected")
                        continue
                    }
                    switch probe {
                    case .unanswered: XCTAssertEqual(gate, .checking)
                    case .available: XCTAssertEqual(gate, .active, "a working grant counts as active, even with an unknown plan")
                    case .unavailable(let sentence): XCTAssertEqual(gate, .noGrant(sentence))
                    case .failed(let sentence): XCTAssertEqual(gate, .failed(sentence))
                    }
                }
            }
        }
    }

    func testUnknownPlanNeverLocksAndNeverShowsInstallOrLocked() {
        for connected in [false, true] {
            for probe in [TBDConnectorsProbe.unanswered, .available, .unavailable("x"), .failed("y")] {
                let gate = TBDConnectors.decide(access: .unknown, agentConnected: connected, probe: probe)
                XCTAssertNotEqual(gate, .locked)
                XCTAssertNotEqual(gate, .install)
            }
        }
    }

    func testGateLinesAndActions() {
        XCTAssertEqual(TBDConnectorsGate.install.message, "Connect is paid for. Install it in Portal.")
        XCTAssertEqual(TBDConnectorsGate.install.action, .openPortal)
        XCTAssertEqual(TBDConnectorsGate.locked.message, "Connectors: available with Connect.")
        XCTAssertEqual(TBDConnectorsGate.locked.action, .none)
        XCTAssertEqual(TBDConnectorsGate.notConnected.message, "Connect TBD's agent to your workspace first.")
        XCTAssertEqual(TBDConnectorsGate.notConnected.action, .connectAgent)
        XCTAssertEqual(TBDConnectorsGate.checking.message, "Checking Connect…")
        XCTAssertEqual(TBDConnectorsGate.noGrant("TBD's agent has no Connect access.").message, "TBD's agent has no Connect access.")
        XCTAssertEqual(TBDConnectorsGate.failed("Connect did not answer in time. Try again.").message, "Connect did not answer in time. Try again.")
        XCTAssertNil(TBDConnectorsGate.active.message)
        XCTAssertEqual(TBDConnectorsGate.signedOut.action, .signIn)
    }

    // MARK: Access words (C276)

    func testAccessWordsNeverSayUpdateAlone() {
        XCTAssertEqual(TBDConnectorAccess.read.words, "Read")
        XCTAssertEqual(TBDConnectorAccess.readUpdate.words, "Read + create + update")
        XCTAssertEqual(TBDConnectorAccess.readUpdateDelete.words, "Full (+ delete)")
        for access in [TBDConnectorAccess.read, .readUpdate, .readUpdateDelete] {
            XCTAssertNotEqual(access.words, "Update")
            XCTAssertNotEqual(access.words, "Read + update")
        }
        XCTAssertEqual(TBDConnectorKind.asMe.words, "as you")
        XCTAssertEqual(TBDConnectorKind.asItself.words, "as TBD")
    }

    func testServiceNames() {
        XCTAssertEqual(TBDConnectors.serviceName("gmail"), "Gmail")
        XCTAssertEqual(TBDConnectors.serviceName("googlecalendar"), "Google Calendar")
        XCTAssertEqual(TBDConnectors.serviceName("github"), "GitHub")
        XCTAssertEqual(TBDConnectors.serviceName("some_new-service"), "Some New Service")
    }

    // MARK: Read-only hint

    func testReadOnlyHintOnlyWhenEveryAccountIsRead() {
        func account(_ id: String, _ access: TBDConnectorAccess) -> TBDConnectorAccount {
            TBDConnectorAccount(id: id, label: id, service: "gmail", kind: .asMe, access: access)
        }
        XCTAssertFalse(TBDConnectors.showsReadOnlyHint([]), "no hint for an empty list")
        XCTAssertTrue(TBDConnectors.showsReadOnlyHint([account("a", .read)]))
        XCTAssertTrue(TBDConnectors.showsReadOnlyHint([account("a", .read), account("b", .read)]))
        XCTAssertFalse(TBDConnectors.showsReadOnlyHint([account("a", .read), account("b", .readUpdate)]))
        XCTAssertFalse(TBDConnectors.showsReadOnlyHint([account("a", .readUpdateDelete)]))
        XCTAssertEqual(TBDConnectors.readOnlyHint,
                       "TBD can read with these accounts. To let TBD send, give it 'Read + create + update' in Portal and in Connect.")
    }

    // MARK: Links

    func testConnectLinksUsePortalLauncher() {
        XCTAssertEqual(TBDConnectors.connectLink(issuer: "https://portal.tealbrick.com", workspace: "ws_1", newAccount: false)?.absoluteString,
                       "https://portal.tealbrick.com/w/ws_1/open?product=connect&path=/configure#agents")
        XCTAssertEqual(TBDConnectors.connectLink(issuer: "https://portal.tealbrick.com", workspace: "ws_1", newAccount: true)?.absoluteString,
                       "https://portal.tealbrick.com/w/ws_1/open?product=connect&path=/")
        // A trailing slash, a dev Portal and an id with a slash.
        XCTAssertEqual(TBDConnectors.connectLink(issuer: "https://dev.tealbrick.com/", workspace: "w/1 x", newAccount: false)?.absoluteString,
                       "https://dev.tealbrick.com/w/w%2F1%20x/open?product=connect&path=/configure#agents")
    }

    func testNoLinkWithoutAWebPortalOrAWorkspace() {
        XCTAssertNil(TBDConnectors.connectLink(issuer: "", workspace: "ws_1", newAccount: false))
        XCTAssertNil(TBDConnectors.connectLink(issuer: "file:///etc", workspace: "ws_1", newAccount: false))
        XCTAssertNil(TBDConnectors.connectLink(issuer: "javascript:alert(1)", workspace: "ws_1", newAccount: true))
        XCTAssertNil(TBDConnectors.connectLink(issuer: "https://portal.tealbrick.com", workspace: "", newAccount: false))
    }

    /// N6: a link goes only to an https Portal; an http issuer gives no link, and the public Portal is the fallback to open.
    func testOnlyAnHttpsPortalGetsALink() {
        XCTAssertNil(TBDConnectors.connectLink(issuer: "http://portal.tealbrick.com", workspace: "ws_1", newAccount: false))
        XCTAssertNil(TBDConnectors.connectLink(issuer: "http://localhost:3000", workspace: "ws_1", newAccount: true))
        XCTAssertNil(TBDConnectors.connectLink(issuer: "HTTP://portal.tealbrick.com", workspace: "ws_1", newAccount: true))
        XCTAssertNotNil(TBDConnectors.connectLink(issuer: "HTTPS://portal.tealbrick.com", workspace: "ws_1", newAccount: true))
        XCTAssertEqual(TBDConnectors.portalURL(issuer: "http://portal.tealbrick.com").absoluteString, "https://portal.tealbrick.com")
    }

    func testPortalURL() {
        XCTAssertEqual(TBDConnectors.portalURL(issuer: "https://dev.tealbrick.com/").absoluteString, "https://dev.tealbrick.com")
        XCTAssertEqual(TBDConnectors.portalURL(issuer: "").absoluteString, "https://portal.tealbrick.com")
        XCTAssertEqual(TBDConnectors.portalURL(issuer: "ftp://x").absoluteString, "https://portal.tealbrick.com")
    }

    // MARK: Remembered choices

    func testChoicesTextNamesTheDefaultAccountForEveryKeptForm() {
        for account in ["", "default", "(default account)"] {
            XCTAssertEqual(TBDConnectorChoice(account: account, tool: "gmail_send_email", decision: .always).text, "Always allow · gmail_send_email · default account", account)
        }
        XCTAssertEqual(TBDConnectorChoice(account: "work inbox", tool: "gmail_send_email", decision: .never).text, "Never allow · gmail_send_email · work inbox")
    }

    func testChoicesAnswerReadsBothShapesAndTheUnreadableFlag() {
        let row: [String: Any] = ["account": "work inbox", "tool": "gmail_send_email", "decision": "always", "at": "2026-10-20T00:00:00Z"]
        let object = TBDConnectorChoices(helperValue: ["choices": [row, ["bad": 1]], "unreadable": true] as [String: Any])
        XCTAssertEqual(object.choices.count, 1)
        XCTAssertTrue(object.unreadable)
        let list = TBDConnectorChoices(helperValue: [row])
        XCTAssertEqual(list.choices.count, 1)
        XCTAssertFalse(list.unreadable, "the earlier bare list has no notice")
        XCTAssertEqual(TBDConnectorChoices(helperValue: nil), TBDConnectorChoices())
        XCTAssertEqual(TBDChoicesIssue.failed.line, "TBD could not read your remembered choices.")
        XCTAssertEqual(TBDChoicesIssue.unreadable.line, "TBD could not read your remembered choices. It kept a copy.")
    }

    // MARK: Helper shapes

    func testAccountsDecode() throws {
        let value: [String: Any] = [
            "available": true,
            "accounts": [
                ["id": "a1", "label": "Work inbox", "service": "gmail", "kind": "as_me", "access": "read_update"],
                ["id": "a2", "label": "Team Slack", "service": "slack", "kind": "as_itself", "access": "read"],
                ["id": "a3", "label": "Bad access", "service": "slack", "kind": "as_me", "access": "update"],
                ["id": "a4", "label": "", "service": "slack", "kind": "as_me", "access": "read"],
                "junk",
            ],
        ]
        let decoded = try XCTUnwrap(TBDConnectorAccounts(helperValue: value))
        XCTAssertTrue(decoded.available)
        XCTAssertEqual(decoded.accounts.map(\.id), ["a1", "a2"], "off-shape rows are dropped, never shown")
        XCTAssertEqual(decoded.accounts[0].access, .readUpdate)
        XCTAssertEqual(decoded.accounts[1].kind, .asItself)
        let off = try XCTUnwrap(TBDConnectorAccounts(helperValue: ["available": false, "reason": "no grant", "accounts": []]))
        XCTAssertFalse(off.available)
        XCTAssertEqual(off.reason, "no grant")
        XCTAssertNil(TBDConnectorAccounts(helperValue: ["accounts": []]))
        XCTAssertNil(TBDConnectorAccounts(helperValue: "text"))
        XCTAssertNil(TBDConnectorAccounts(helperValue: nil))
    }

    func testChoicesDecodeAndText() {
        let value: [Any] = [
            ["account": "Work inbox", "tool": "GMAIL_SEND_EMAIL", "decision": "always", "at": "2026-10-20T01:00:00Z"],
            ["account": "default", "tool": "SLACK_POST", "decision": "never", "at": "2026-10-20T01:00:00Z"],
            ["account": "x", "tool": "T", "decision": "maybe", "at": ""],
            ["account": "x", "decision": "always"],
        ]
        let rows = TBDConnectorChoice.list(helperValue: value)
        XCTAssertEqual(rows.map(\.text), ["Always allow · GMAIL_SEND_EMAIL · Work inbox", "Never allow · SLACK_POST · default account"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(TBDConnectorChoice.list(helperValue: nil), [])
        XCTAssertEqual(TBDConnectors.choicesNote, "These are TBD's own permissions on this Mac. They are not Rules rules (that needs Rules).")
        XCTAssertEqual(TBDConnectors.noChoicesLine, "No remembered choices.")
        XCTAssertEqual(TBDConnectors.emptyAccountsLine, "No account is shared with TBD's agent yet. Share accounts in Connect.")
    }
}
