import Foundation
import TBDModels

/// Downloads a model into Ollama on this Mac (`ollama pull` through its local API) for the setup flow (dev.10).
/// The shared instance owns the task, so a download keeps running when the person goes on (as the speech model,
/// C286 F3); the summary reads `progress`.
@MainActor
final class TBDLocalModelDownload: ObservableObject {
  static let shared = TBDLocalModelDownload()

  /// 0...1 per model while its download runs.
  @Published private(set) var progress: [String: Double] = [:]
  /// The last failure per model, in plain words.
  @Published private(set) var errors: [String: String] = [:]

  private init() {}

  /// Starts the download once; `done` runs on success.
  func pull(_ model: String, done: @escaping @MainActor () -> Void) {
    guard progress[model] == nil else { return }
    progress[model] = 0
    errors[model] = nil
    Task {
      var tracker = TBDOllamaPull.Tracker()
      do {
        let (bytes, response) = try await URLSession.shared.bytes(for: TBDOllamaPull.request(model: model))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
          throw NSError(domain: "TBD.Ollama", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                        userInfo: [NSLocalizedDescriptionKey: "Ollama did not accept the download."])
        }
        var shown = 0.0
        for try await line in bytes.lines {
          tracker.read(line)
          if tracker.error != nil || tracker.done { break }
          // Ollama sends many lines a second; publish whole-percent steps only.
          if let p = tracker.progress, p - shown >= 0.01 { shown = p; progress[model] = p }
        }
      } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
        errors[model] = TBDAgentModelSetup.LocalStatus.notRunning.message
      } catch {
        errors[model] = error.localizedDescription
      }
      if let message = tracker.error { errors[model] = message }
      progress[model] = nil
      if tracker.done { done() }
    }
  }
}
