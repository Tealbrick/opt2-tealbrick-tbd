import XCTest
@testable import TBDModels

final class TBDLocalChoicesTests: XCTestCase {
    private let home = "/Users/me"

    func testTheTextOfEachKind() {
        XCTAssertEqual(TBDLocalChoice(key: "shell:npm test", decision: .always).text(home: home), "Always allow · Run `npm test`")
        XCTAssertEqual(TBDLocalChoice(key: "write:/Users/me/Projects/x", decision: .never).text(home: home), "Never allow · Write in ~/Projects/x")
        XCTAssertEqual(TBDLocalChoice(key: "web:example.com", decision: .always).text(home: home), "Always allow · Fetch from example.com")
        XCTAssertEqual(TBDLocalChoice(key: "websearch", decision: .always).text(home: home), "Always allow · Search the web")
        XCTAssertEqual(TBDLocalChoice(key: "shell:rm -rf build", decision: .never).text(home: home), "Never allow · Run `rm -rf build`")
    }

    func testTheHomeFolderShowsAsTildeOnlyAtAFolderBoundary() {
        XCTAssertEqual(TBDLocalChoice(key: "write:/Users/me", decision: .never).text(home: home), "Never allow · Write in ~")
        XCTAssertEqual(TBDLocalChoice(key: "write:/Users/meow/x", decision: .never).text(home: home), "Never allow · Write in /Users/meow/x", "another user's folder is not under this home")
        XCTAssertEqual(TBDLocalChoice(key: "write:/tmp/x", decision: .never).text(home: home), "Never allow · Write in /tmp/x")
        XCTAssertEqual(TBDLocalChoice(key: "write:/Users/me/a", decision: .never).text(home: "/"), "Never allow · Write in /Users/me/a")
    }

    func testTextThatChangesHowALineReadsIsRemovedAndLongTextEndsWithAnEllipsis() {
        let tricky = TBDLocalChoice(key: "shell:ls \u{202E}gpj.exe\u{202C}\nrm \u{07}x\u{200F}", decision: .never).text(home: home)
        XCTAssertEqual(tricky, "Never allow · Run `ls gpj.exe ⏎ rm x`")
        let long = TBDLocalChoice(key: "shell:" + String(repeating: "a", count: 500), decision: .never).text(home: home)
        XCTAssertTrue(long.hasSuffix("…`"), "a cut is marked")
        XCTAssertEqual(long.count, "Never allow · Run `".count + TBDLocalChoice.displayMax + 1 + 1)
    }

    func testTheHelpersShape() {
        let row: [String: Any] = ["key": "shell:npm test", "decision": "always", "at": "2026-10-20T10:00:00.000Z"]
        XCTAssertEqual(TBDLocalChoice(helperValue: row), TBDLocalChoice(key: "shell:npm test", decision: .always))
        let bads: [[String: Any]] = [["key": "nonsense", "decision": "always"], ["key": "shell:", "decision": "always"], ["key": "write:relative", "decision": "never"],
                                     ["key": "web:", "decision": "never"], ["key": "shell:x", "decision": "maybe"], ["decision": "always"], ["key": 3, "decision": "always"]]
        for bad in bads {
            XCTAssertNil(TBDLocalChoice(helperValue: bad), "\(bad)")
        }
        let object = TBDLocalChoices(helperValue: ["choices": [row, ["bad": 1]], "unreadable": true] as [String: Any])
        XCTAssertEqual(object.choices.count, 1)
        XCTAssertTrue(object.unreadable)
        XCTAssertEqual(TBDLocalChoices(helperValue: [row]).choices.count, 1, "the bare list reads too")
        XCTAssertEqual(TBDLocalChoices(helperValue: nil), TBDLocalChoices())
        XCTAssertEqual(TBDLocalChoices(helperValue: "text"), TBDLocalChoices())
    }

    func testKinds() {
        XCTAssertEqual(TBDLocalChoice.kind(of: "shell:ls"), .shell)
        XCTAssertEqual(TBDLocalChoice.kind(of: "write:/a"), .write)
        XCTAssertEqual(TBDLocalChoice.kind(of: "web:a.example"), .web)
        XCTAssertEqual(TBDLocalChoice.kind(of: "websearch"), .search)
        XCTAssertNil(TBDLocalChoice.kind(of: "gmail_send_email"))
    }

    func testTheWords() {
        XCTAssertEqual(TBDLocalChoices.title, "Your choices for TBD's agent on this Mac")
        XCTAssertEqual(TBDLocalChoices.connectorsLine, "Choices for connected accounts are in Settings › Connectors.")
        XCTAssertEqual(TBDLocalChoices.line(.failed), "TBD could not read your choices for this Mac.")
        XCTAssertEqual(TBDLocalChoices.line(.unreadable), "TBD could not read your choices for this Mac. It kept a copy.")
        XCTAssertEqual(TBDLocalChoices.removeFailedLine, "TBD could not forget that choice. Try again.")
    }
}
