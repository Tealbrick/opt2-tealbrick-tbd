import XCTest
@testable import TBDModels

/// The setup flow's Ollama download (dev.10): the request and the progress over a real-shaped stream.
final class TBDOllamaPullTests: XCTestCase {
    func testRequestAsksForAStreamedPull() throws {
        let request = TBDOllamaPull.request(model: "qwen3-vl:4b")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/pull")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "qwen3-vl:4b")
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testProgressCountsEveryLayerAndEndsAtOne() {
        var t = TBDOllamaPull.Tracker()
        t.read(#"{"status":"pulling manifest"}"#)
        XCTAssertNil(t.progress)
        t.read(#"{"status":"pulling a1","digest":"sha256:a1","total":3000,"completed":0}"#)
        t.read(#"{"status":"pulling a1","digest":"sha256:a1","total":3000,"completed":1500}"#)
        t.read(#"{"status":"pulling b2","digest":"sha256:b2","total":1000,"completed":500}"#)
        XCTAssertEqual(t.progress ?? -1, 0.5, accuracy: 0.0001)
        t.read("not json")
        t.read(#"{"status":"verifying sha256 digest"}"#)
        XCTAssertFalse(t.done)
        t.read(#"{"status":"success"}"#)
        XCTAssertTrue(t.done)
        XCTAssertEqual(t.progress, 1)
        XCTAssertNil(t.error)
    }

    func testAnErrorLineStopsWithTheMessage() {
        var t = TBDOllamaPull.Tracker()
        t.read(#"{"error":"pull model manifest: file does not exist"}"#)
        XCTAssertEqual(t.error, "pull model manifest: file does not exist")
        XCTAssertFalse(t.done)
    }
}
