import Foundation

/// Downloading a model into Ollama on this Mac from the setup flow (dev.10, follow-up 4): `POST /api/pull` with
/// `stream: true` answers one JSON object per line (`status`, and while a layer downloads `digest`, `total`,
/// `completed`; `error` on failure; `status: "success"` at the end). Pure parts here; the app streams the lines.
public enum TBDOllamaPull {
    public static func request(model: String, endpoint: String = TBDAgentModelSetup.ollamaEndpoint) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint + "/api/pull")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        // An idle timeout (no data for this long), not a total: a large model takes many minutes and the stream keeps
        // sending progress lines.
        request.timeoutInterval = 600
        return request
    }

    /// Follows the stream: overall progress over every layer seen so far (by bytes).
    public struct Tracker: Equatable, Sendable {
        public private(set) var totals: [String: Int64] = [:]
        public private(set) var completed: [String: Int64] = [:]
        public private(set) var done = false
        public private(set) var error: String?
        public init() {}

        /// 0...1, or nil before the first layer reports its size.
        public var progress: Double? {
            let total = totals.values.reduce(0, +)
            guard total > 0 else { return done ? 1 : nil }
            return done ? 1 : min(1, Double(completed.values.reduce(0, +)) / Double(total))
        }

        /// Reads one line of the stream. Unknown or broken lines are ignored.
        public mutating func read(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            if let message = json["error"] as? String { error = message; return }
            if let digest = json["digest"] as? String {
                if let total = (json["total"] as? NSNumber)?.int64Value, total > 0 { totals[digest] = total }
                if let part = (json["completed"] as? NSNumber)?.int64Value { completed[digest] = part }
            }
            if (json["status"] as? String) == "success" { done = true }
        }
    }
}
