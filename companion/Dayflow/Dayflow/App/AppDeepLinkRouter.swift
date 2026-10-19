import Foundation
import TBDModels

@MainActor
final class AppDeepLinkRouter {
  enum Action: String {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case analyze = "analyze"
    case retryAnalysis = "retry-analysis"

    init?(identifier: String) {
      switch identifier.lowercased() {
      case Self.startRecording.rawValue, "start", "resume":
        self = .startRecording
      case Self.stopRecording.rawValue, "stop", "pause":
        self = .stopRecording
      case Self.retryAnalysis.rawValue:
        self = .retryAnalysis
      case Self.analyze.rawValue:
        self = .analyze
      default:
        return nil
      }
    }
  }

  init() {}

  @discardableResult
  func handle(_ url: URL) -> Bool {
    guard let action = resolveAction(from: url) else {
      print("[DeepLink] Unsupported URL: \(url.absoluteString)")
      return false
    }

    perform(action, url: url)
    return true
  }

  private func resolveAction(from url: URL) -> Action? {
    #if DEBUG
      let expectedScheme = TBDIdentity.isDev ? "tealbrick-desktop-dev" : "tealbrick-desktop"
    #else
      let expectedScheme = "tealbrick-desktop"
    #endif
    guard let scheme = url.scheme, scheme.caseInsensitiveCompare(expectedScheme) == .orderedSame else {
      return nil
    }

    var candidates: [String] = []
    if let host = url.host, !host.isEmpty {
      candidates.append(host)
    }

    let pathComponents = url.path
      .split(separator: "/")
      .map { String($0) }

    candidates.append(contentsOf: pathComponents)

    if candidates.isEmpty {
      if let actionItem = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first(where: { $0.name.lowercased() == "action" }),
        let value = actionItem.value, !value.isEmpty
      {
        candidates.append(value)
      }
    }

    guard let identifier = candidates.first else { return nil }
    return Action(identifier: identifier)
  }

  private func perform(_ action: Action, url: URL) {
    switch action {
    case .retryAnalysis:
      if let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "batch" })?.value,
         let id = Int64(raw), id > 0 {
        AnalysisManager.shared.reprocessBatch(id, stepHandler: { _ in }, completion: { _ in })
      }
    case .analyze:
      AnalysisManager.shared.analyzePendingActivity()
    case .startRecording:
      startRecording()
    case .stopRecording:
      stopRecording()
    }
  }

  private func startRecording() {
    guard RecordingControl.currentMode() != .active else {
      print("[DeepLink] Recording already active; ignoring start request")
      return
    }
    RecordingControl.start(reason: "deeplink")
  }

  private func stopRecording() {
    guard RecordingControl.currentMode() != .stopped else {
      print("[DeepLink] Recording already stopped; ignoring stop request")
      return
    }
    RecordingControl.stop(reason: "deeplink")
  }

}
