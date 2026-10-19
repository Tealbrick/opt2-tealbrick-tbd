import XCTest

@testable import TBD

/// dev.10 (Coordinator check): the person's model key, which the Chat helper puts in TBD's agent's environment, is
/// never written to ~/Library/Logs/<app>/chat-helper.log, even if an error line quotes it. Second layer behind the
/// helper's own scrub (chat/test/agent-key-logs.test.ts).
final class HelperLogRedactionTests: XCTestCase {
  // Realistic shapes, not real keys.
  private let keys = [
    "sk-ant-api03-Zx9LEAKCHECKaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1-bbbbbbAA",  // Anthropic
    "0123456789abcdef0123456789abcdef",  // Microsoft Foundry (32 hex)
    "ABSKQmVkcm9ja0FQSUtleS1MRUFLQ0hFQ0sxMjM0NTY3ODkwYWJjZGVmZ2hpams=",  // Bedrock API key (base64)
  ]

  func testErrorLinesNeverKeepAKey() {
    for key in keys {
      let lines = [
        "[helper:error] unhandled rejection: Error: provider refused key \(key)",
        "[helper:error] native agentModel failed: ANTHROPIC_FOUNDRY_API_KEY=\(key)",
        "Error: 401 {\"error\":{\"message\":\"invalid x-api-key: \(key)\"}}",
        "fatal: Authorization: Bearer \(key)",
      ]
      for line in lines {
        let out = TBDHelperLog.redact(line)
        XCTAssertFalse(out.contains(key), "key kept in: \(out)")
        XCTAssertFalse(out.contains(String(key.prefix(16))), "key prefix kept in: \(out)")
      }
    }
  }

  func testOrdinaryErrorTextStaysReadable() {
    XCTAssertEqual(TBDHelperLog.redact("[helper:error] uncaught exception: TypeError: x is undefined"),
                   "[helper:error] uncaught exception: TypeError: x is undefined")
  }
}
