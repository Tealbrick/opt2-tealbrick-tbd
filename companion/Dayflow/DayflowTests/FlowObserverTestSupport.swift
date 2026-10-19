import XCTest
import TBDModels

@testable import TBD

/// A screen source that never touches ScreenCaptureKit or Vision: it writes bytes to the file and returns canned text.
final class FakeScreenSource: FlowScreenSource, @unchecked Sendable {
  static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02, 0x03])
  private let lock = NSLock()
  private var _captures = 0
  private var _recognitions = 0
  private var _urls: [URL] = []
  var text = "Xcode — FlowDistractionAgent.swift — Write report"
  var failure: Error?

  var captures: Int { lock.lock(); defer { lock.unlock() }; return _captures }
  var recognitions: Int { lock.lock(); defer { lock.unlock() }; return _recognitions }
  var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }

  func capture(to url: URL, height: Int, quality: Double) async throws {
    lock.lock(); _captures += 1; _urls.append(url); let failure = self.failure; lock.unlock()
    if let failure { throw failure }
    try Self.jpeg.write(to: url)
  }

  func recognizeText(at url: URL) -> String {
    lock.lock(); _recognitions += 1; lock.unlock()
    return text
  }
}

/// A model that answers from a script and records every call.
final class ScriptedModel: TBDFlowModelCompleting, @unchecked Sendable {
  struct Call {
    let system: String
    let userText: String
    let imageJPEG: Data?
    let config: TBDModelConfig
  }
  private let lock = NSLock()
  private var _calls: [Call] = []
  private var replies: [Result<String, Error>] = []
  /// Used when the script is empty.
  var fallback: Result<String, Error> = .success(#"{"status":"on_task","action":"none"}"#)

  var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
  func queue(_ reply: String) { lock.lock(); replies.append(.success(reply)); lock.unlock() }
  func queueFailure(_ error: Error) { lock.lock(); replies.append(.failure(error)); lock.unlock() }

  func complete(system: String, userText: String, imageJPEG: Data?, config: TBDModelConfig, timeout: TimeInterval) async throws -> String {
    lock.lock()
    _calls.append(Call(system: system, userText: userText, imageJPEG: imageJPEG, config: config))
    let next = replies.isEmpty ? fallback : replies.removeFirst()
    lock.unlock()
    return try next.get()
  }
}

final class LocalProblemBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: TBDFlowObserverError?
  var value: TBDFlowObserverError? {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); _value = newValue; lock.unlock() }
  }
}

/// A test case with an observer wired to fakes, on its own registry and defaults.
@MainActor
class FlowObserverTestCase: FlowTestCase {
  var registry: TBDModelRegistry!
  var setup: TBDFlowObserverSetup!
  var model: ScriptedModel!
  var screen: FakeScreenSource!
  var agent: FlowDistractionAgent!
  let problemBox = LocalProblemBox()
  var localProblem: TBDFlowObserverError? {
    get { problemBox.value }
    set { problemBox.value = newValue }
  }

  override func setUp() async throws {
    try await super.setUp()
    registry = TBDModelRegistry(defaults: defaults, credentials: TBDMemorySecretStore())
    let clock = self.clock
    setup = TBDFlowObserverSetup(registry: registry, defaults: defaults, clock: { clock.now })
    model = ScriptedModel()
    screen = FakeScreenSource()
    localProblem = nil
    agent = makeAgent()
  }

  func makeAgent() -> FlowDistractionAgent {
    let clock = self.clock
    let box = problemBox
    return FlowDistractionAgent(
      setup: setup, client: model, source: screen, settings: settings, timeline: timeline, mirror: mirror, defaults: defaults,
      localCheck: { _ in box.value }, frontApp: { .none },
      now: { clock.now }, schedulesTimer: false, tempRoot: folder)
  }

  /// A local route on Ollama and the switch on.
  func turnOn(_ mode: TBDFlowObserverMode = .textLocal, modelName: String = "llama3.2:3b") throws {
    try setup.chooseLocal(mode, model: modelName)
    setup.watching = true
  }

  /// Starts a session on the agent (and the mirror, so nudges can show) and waits for the start-up check.
  func startSession(style: FlowAlertStyle = .friendly) async {
    let snap = snapshot(.active, style: style)
    mirror.apply(snap)
    agent.start(with: snap, rebrief: false)
    await agent.startTask?.value
  }

  /// One check, awaited.
  func check() async {
    await agent.tick()?.value
  }

  func files(in url: URL?) -> [String] {
    guard let url else { return [] }
    return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
  }
}
