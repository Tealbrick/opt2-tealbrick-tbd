import XCTest
@testable import TBDModels

/// A URLProtocol that answers every request itself: no real network.
final class FlowStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping (URLRequest) -> (Int, [String: String], Data)) {
        lock.lock(); self.handler = handler; requests = []; lock.unlock()
    }
    static var seen: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            copy.httpBody = data
        }
        Self.requests.append(copy)
        let handler = Self.handler
        Self.lock.unlock()
        guard let (status, headers, body) = handler?(copy), let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        if (300..<400).contains(status), let location = headers["Location"], let target = URL(string: location) {
            // A refused redirect leaves the 3xx answer as the result; a followed one starts a new request.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class TBDFlowModelClientTests: XCTestCase {
    private var client: TBDFlowModelClient!
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlowStubProtocol.self]
        client = TBDFlowModelClient(session: URLSession(configuration: configuration))
    }

    private func openAI(key: String? = nil, base: String = "http://localhost:11434/v1", local: Bool = true) -> TBDModelConfig {
        TBDModelConfig(kind: .openAICompatible, baseURL: URL(string: base)!, apiKey: key, model: "llama3.2:3b", isLocal: local)
    }
    private func anthropic(key: String = "sk-ant-secret-key") -> TBDModelConfig {
        TBDModelConfig(kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com")!, apiKey: key, model: "claude-test", isLocal: false)
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private func okOpenAI(_ text: String) -> (Int, [String: String], Data) {
        (200, [:], try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": text]]]]))
    }

    func testOpenAICompatibleTextRequestShape() async throws {
        FlowStubProtocol.reset { _ in self.okOpenAI("{\"status\":\"on_task\"}") }
        let reply = try await client.complete(system: "SYS", userText: "USER", imageJPEG: nil, config: openAI(), timeout: 30)
        XCTAssertEqual(reply, "{\"status\":\"on_task\"}")
        let request = try XCTUnwrap(FlowStubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no key, no header")
        XCTAssertEqual(request.timeoutInterval, 30)
        let json = try body(request)
        XCTAssertEqual(json["model"] as? String, "llama3.2:3b")
        XCTAssertEqual(json["max_tokens"] as? Int, 1200)
        XCTAssertEqual(json["temperature"] as? Double, 0.1)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "SYS")
        XCTAssertEqual(messages[1]["content"] as? String, "USER", "text only: the content is a plain string")
    }

    func testOpenAICompatibleImageRequestShapeAndBearerKey() async throws {
        FlowStubProtocol.reset { _ in self.okOpenAI("ok") }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        _ = try await client.complete(system: "S", userText: "U", imageJPEG: jpeg, config: openAI(key: "k-bearer-1", base: "https://gw.example.com/v1", local: false), timeout: 20)
        let request = try XCTUnwrap(FlowStubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://gw.example.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k-bearer-1")
        let messages = try XCTUnwrap(try body(request)["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "U")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let url = try XCTUnwrap((parts[1]["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertEqual(url, "data:image/jpeg;base64," + jpeg.base64EncodedString())
    }

    func testAnthropicRequestShape() async throws {
        FlowStubProtocol.reset { _ in
            (200, [:], try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "hello"]]]))
        }
        let jpeg = Data([1, 2, 3])
        let reply = try await client.complete(system: "SYS", userText: "USER", imageJPEG: jpeg, config: anthropic(), timeout: 25)
        XCTAssertEqual(reply, "hello")
        let request = try XCTUnwrap(FlowStubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request)
        XCTAssertEqual(json["system"] as? String, "SYS")
        XCTAssertEqual(json["max_tokens"] as? Int, 1200)
        XCTAssertEqual(json["temperature"] as? Double, 0.1)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        let blocks = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["image", "text"])
        let source = try XCTUnwrap(blocks[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, jpeg.base64EncodedString())
        XCTAssertEqual(blocks[1]["text"] as? String, "USER")
    }

    func testAnthropicTextOnlyHasNoImageBlock() async throws {
        FlowStubProtocol.reset { _ in (200, [:], try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": "x"]]])) }
        _ = try await client.complete(system: "S", userText: "U", imageJPEG: nil, config: anthropic(), timeout: 5)
        let blocks = try XCTUnwrap(((try body(XCTUnwrap(FlowStubProtocol.seen.first))["messages"] as? [[String: Any]])?[0]["content"]) as? [[String: Any]])
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text"])
    }

    func testTheKeyNeverAppearsInAnError() async throws {
        let key = "sk-ant-secret-key"
        FlowStubProtocol.reset { _ in (401, [:], Data("invalid x-api-key: \(key) (and Bearer \(key))".utf8)) }
        do {
            _ = try await client.complete(system: "S", userText: "U", imageJPEG: nil, config: anthropic(key: key), timeout: 5)
            XCTFail("expected an error")
        } catch {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains(key), text)
            XCTAssertTrue(text.contains("HTTP 401"), text)
            XCTAssertFalse(String(describing: error).contains(key), "\(error)")
        }
    }

    func testOnlyTheConfiguredHostSeesTheRequest() async throws {
        FlowStubProtocol.reset { _ in self.okOpenAI("ok") }
        _ = try await client.complete(system: "S", userText: "U", imageJPEG: Data([1]), config: openAI(key: "k-1234", base: "https://gw.example.com/v1", local: false), timeout: 5)
        XCTAssertEqual(Set(FlowStubProtocol.seen.compactMap { $0.url?.host }), ["gw.example.com"])
        XCTAssertEqual(FlowStubProtocol.seen.count, 1)
    }

    func testARedirectToAnotherHostIsRefusedAndTheKeyIsNotSent() async throws {
        FlowStubProtocol.reset { request in
            request.url?.host == "gw.example.com" ? (302, ["Location": "https://evil.example.org/steal"], Data()) : self.okOpenAI("leaked")
        }
        do {
            _ = try await client.complete(system: "S", userText: "U", imageJPEG: nil, config: openAI(key: "k-1234", base: "https://gw.example.com/v1", local: false), timeout: 5)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? TBDFlowModelError, .redirected)
        }
        XCTAssertEqual(Set(FlowStubProtocol.seen.compactMap { $0.url?.host }), ["gw.example.com"])
    }

    func testEmptyReplyAndUnreachableLocalServer() async throws {
        FlowStubProtocol.reset { _ in self.okOpenAI("   ") }
        do { _ = try await client.complete(system: "S", userText: "U", imageJPEG: nil, config: openAI(), timeout: 5); XCTFail() }
        catch { XCTAssertEqual(error as? TBDFlowModelError, .emptyReply) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        let down = TBDFlowModelClient(session: URLSession(configuration: configuration))
        do { _ = try await down.complete(system: "S", userText: "U", imageJPEG: nil, config: openAI(), timeout: 5); XCTFail() }
        catch { XCTAssertEqual(error.localizedDescription, "Ollama is not running on this Mac.") }
    }

    func testScrubLeavesShortOrMissingKeysAlone() {
        XCTAssertEqual(TBDFlowModelClient.scrub("abc", key: nil), "abc")
        XCTAssertEqual(TBDFlowModelClient.scrub("a key-1234 b", key: "key-1234"), "a [key removed] b")
    }
}

private final class FailingProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}
