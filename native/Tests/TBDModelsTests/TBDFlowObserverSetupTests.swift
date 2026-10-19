import XCTest
@testable import TBDModels

final class TBDFlowObserverSetupTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func make(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> (TBDFlowObserverSetup, TBDModelRegistry, UserDefaults) {
        let name = "tbd.tests.flow-observer.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        let registry = TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore())
        return (TBDFlowObserverSetup(registry: registry, defaults: defaults, clock: { now }), registry, defaults)
    }

    func testTaskExistsAndAssignWorks() throws {
        let (_, registry, _) = make()
        XCTAssertTrue(TBDModelTask.allCases.contains(.flow))
        let c = TBDModelConnection(name: "Local", endpoint: "http://localhost:11434/v1")
        try registry.saveConnection(c, apiKey: nil)
        try registry.assign(TBDModelRoute(connectionID: c.id, model: "llama3.2:3b"), to: "flow")
        XCTAssertEqual(try registry.configuration(for: .flow)?.model, "llama3.2:3b")
    }

    func testDefaultsAreOffAndTextLocal() {
        let (setup, _, _) = make()
        XCTAssertFalse(setup.watching, "Q2: off until the person turns it on")
        XCTAssertEqual(setup.mode, .textLocal)
        XCTAssertNil(setup.cloudConsentAt)
        XCTAssertThrowsError(try setup.resolve()) { XCTAssertEqual($0 as? TBDFlowObserverError, .notSetUp) }
        XCTAssertEqual(TBDFlowObserverError.notSetUp.errorDescription, "Set up a model for the Flow observer in Flow › Observer.")
    }

    func testChoicesAreStored() {
        let (setup, _, defaults) = make()
        setup.watching = true
        setup.mode = .visionLocal
        let again = TBDFlowObserverSetup(registry: TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore()), defaults: defaults)
        XCTAssertTrue(again.watching)
        XCTAssertEqual(again.mode, .visionLocal)
        XCTAssertEqual(TBDFlowObserverSetup.watchingKey, "tbd.flow.observer.on")
        XCTAssertEqual(TBDFlowObserverSetup.modeKey, "tbd.flow.observer.mode")
        XCTAssertEqual(TBDFlowObserverSetup.cloudConsentKey, "tbd.flow.observer.cloudConsent")
    }

    func testTextLocalResolvesToTextEvidenceOnOllama() throws {
        let (setup, registry, _) = make()
        try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
        let route = try setup.resolve()
        XCTAssertEqual(route.mode, .textLocal)
        XCTAssertEqual(route.evidence, .text)
        XCTAssertEqual(route.config.kind, .openAICompatible)
        XCTAssertEqual(route.config.baseURL.absoluteString, "http://localhost:11434/v1")
        XCTAssertNil(route.config.apiKey)
        XCTAssertTrue(route.config.isLocal)
        XCTAssertEqual(route.config.model, "llama3.2:3b")
        XCTAssertEqual(try registry.load().connections.count, 1)
    }

    func testVisionLocalResolvesToImageEvidence() throws {
        let (setup, _, _) = make()
        try setup.chooseLocal(.visionLocal, model: TBDFlowObserverSetup.defaultVisionModel)
        let route = try setup.resolve()
        XCTAssertEqual(route.evidence, .image)
        XCTAssertEqual(route.config.model, "qwen2.5vl:3b")
        XCTAssertEqual(setup.rememberedModel(for: .visionLocal), "qwen2.5vl:3b")
    }

    func testAnExistingOllamaConnectionIsReused() throws {
        let (setup, registry, _) = make()
        let existing = TBDModelConnection(name: "My Ollama", endpoint: "http://localhost:11434/v1/", kind: .openAICompatible)
        try registry.saveConnection(existing, apiKey: nil)
        try setup.chooseLocal(.textLocal, model: "a")
        try setup.chooseLocal(.visionLocal, model: "b")
        XCTAssertEqual(try registry.load().connections.map(\.id), [existing.id])
        XCTAssertEqual(try registry.load().routes["flow"]?.connectionID, existing.id)
    }

    func testALocalModeNeverResolvesToARouteOffThisMac() throws {
        let (setup, registry, _) = make()
        let cloud = TBDModelConnection(name: "Gateway", endpoint: "https://gateway.example.com/v1", kind: .openAICompatible)
        try registry.saveConnection(cloud, apiKey: "k-123456")
        try registry.assign(TBDModelRoute(connectionID: cloud.id, model: "m"), to: "flow")
        for mode in [TBDFlowObserverMode.textLocal, .visionLocal] {
            setup.mode = mode
            XCTAssertThrowsError(try setup.resolve(), "\(mode)") { XCTAssertEqual($0 as? TBDFlowObserverError, .notSetUp) }
        }
    }

    func testCloudRefusesWithoutConsent() throws {
        let (setup, registry, defaults) = make()
        let c = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
        try registry.saveConnection(c, apiKey: "sk-test-1234")
        try registry.assign(TBDModelRoute(connectionID: c.id, model: "claude-test"), to: "flow")
        setup.mode = .cloud
        XCTAssertThrowsError(try setup.resolve()) { XCTAssertEqual($0 as? TBDFlowObserverError, .cloudNeedsConsent) }
        // A consent date for another connection does not count.
        defaults.set(1.0, forKey: TBDFlowObserverSetup.cloudConsentKey)
        defaults.set("other", forKey: "tbd.flow.observer.cloudConsentConnection")
        XCTAssertThrowsError(try setup.resolve()) { XCTAssertEqual($0 as? TBDFlowObserverError, .cloudNeedsConsent) }
    }

    func testChoosingCloudRecordsConsentAndResolvesToImage() throws {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        let (setup, registry, _) = make(now: when)
        let c = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
        try registry.saveConnection(c, apiKey: "sk-test-1234")
        try setup.chooseCloud(connectionID: c.id, model: "claude-test")
        XCTAssertEqual(setup.cloudConsentAt, when)
        let route = try setup.resolve()
        XCTAssertEqual(route.mode, .cloud)
        XCTAssertEqual(route.evidence, .image)
        XCTAssertFalse(route.config.isLocal)
        XCTAssertEqual(route.config.apiKey, "sk-test-1234")
    }

    func testChangingTheCloudConnectionNeedsANewChoice() throws {
        let (setup, registry, _) = make()
        let a = TBDModelConnection(name: "A", endpoint: "https://a.example.com/v1")
        let b = TBDModelConnection(name: "B", endpoint: "https://b.example.com/v1")
        try registry.saveConnection(a, apiKey: "ka-1234")
        try registry.saveConnection(b, apiKey: "kb-1234")
        try setup.chooseCloud(connectionID: a.id, model: "m")
        XCTAssertNoThrow(try setup.resolve())
        // The route moves to B without the person's tap on B (for example Settings › Models): refused.
        try registry.assign(TBDModelRoute(connectionID: b.id, model: "m"), to: "flow")
        XCTAssertThrowsError(try setup.resolve()) { XCTAssertEqual($0 as? TBDFlowObserverError, .cloudNeedsConsent) }
    }

    func testChoosingALocalModeWithdrawsTheConsent() throws {
        let (setup, registry, _) = make()
        let c = TBDModelConnection(name: "A", endpoint: "https://a.example.com/v1")
        try registry.saveConnection(c, apiKey: nil)
        try setup.chooseCloud(connectionID: c.id, model: "m")
        XCTAssertNotNil(setup.cloudConsentAt)
        try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
        XCTAssertNil(setup.cloudConsentAt)
        XCTAssertNil(setup.cloudConsentConnectionID)
    }

    func testAnthropicCloudNeedsAKey() throws {
        let (setup, registry, _) = make()
        let c = TBDModelConnection(name: "Anthropic", endpoint: "https://api.anthropic.com", kind: .anthropic)
        try registry.saveConnection(c, apiKey: nil)
        try setup.chooseCloud(connectionID: c.id, model: "claude-test")
        XCTAssertThrowsError(try setup.resolve()) { XCTAssertEqual($0 as? TBDFlowObserverError, .cloudNeedsKey) }
    }

    func testCloudChoiceRejectsAnUnknownConnectionOrEmptyModel() {
        let (setup, _, _) = make()
        XCTAssertThrowsError(try setup.chooseCloud(connectionID: "nope", model: "m"))
        XCTAssertThrowsError(try setup.chooseLocal(.textLocal, model: "  "))
        XCTAssertNil(setup.cloudConsentAt)
    }

    func testDefaultTextModelPrefersAnOllamaAgentRoute() throws {
        let (setup, registry, _) = make()
        XCTAssertEqual(setup.defaultTextModel(installed: ["nomic-embed-text", "llama3.2:3b", "qwen:7b"]), "llama3.2:3b", "the first installed, not an embedding model")
        XCTAssertNil(setup.defaultTextModel(installed: []))
        _ = try TBDAgentModelSetup.save(provider: .ollama, endpoint: "", apiKey: "", model: "gpt-oss:20b", registry: registry)
        XCTAssertEqual(setup.defaultTextModel(installed: ["llama3.2:3b"]), "gpt-oss:20b")
        // A hosted agent route is not a local model.
        let (setup2, registry2, _) = make()
        _ = try TBDAgentModelSetup.save(provider: .anthropic, endpoint: "", apiKey: "sk-ant-test", model: "claude-test", registry: registry2)
        XCTAssertEqual(setup2.defaultTextModel(installed: ["llama3.2:3b"]), "llama3.2:3b")
    }

    func testLocalProblemChecksOllamaAndTheModel() async throws {
        let (setup, _, _) = make()
        try setup.chooseLocal(.textLocal, model: "llama3.2:3b")
        let route = try setup.resolve()
        func tags(_ names: [String], status: Int = 200) -> (URLRequest) async throws -> (Data, URLResponse) {
            { request in
                XCTAssertEqual(request.url?.host, "localhost")
                let body = try JSONSerialization.data(withJSONObject: ["models": names.map { ["name": $0] }])
                return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let ready = await TBDFlowObserverSetup.localProblem(for: route, transport: tags(["llama3.2:3b"]))
        XCTAssertNil(ready)
        let missing = await TBDFlowObserverSetup.localProblem(for: route, transport: tags(["other:1b"]))
        XCTAssertEqual(missing, .modelMissing("llama3.2:3b"))
        let down = await TBDFlowObserverSetup.localProblem(for: route, transport: { _ in throw URLError(.cannotConnectToHost) })
        XCTAssertEqual(down, .ollamaNotRunning)
        XCTAssertEqual(TBDFlowObserverError.ollamaNotRunning.errorDescription, "Ollama is not running on this Mac.")
    }

    func testTheWordsForThePage() {
        XCTAssertEqual(TBDFlowObserverSetup.providerName(TBDModelConnection(name: "x", endpoint: "https://api.anthropic.com", kind: .anthropic)), "Anthropic")
        XCTAssertEqual(TBDFlowObserverSetup.providerName(TBDModelConnection(name: "My gateway", endpoint: "https://gw.example.com/v1")), "My gateway")
        XCTAssertEqual(TBDFlowObserverSetup.consentSentence(provider: "Anthropic"),
                       "Every 15 seconds a screenshot goes to Anthropic. Use this only if you accept that.")
    }
}
