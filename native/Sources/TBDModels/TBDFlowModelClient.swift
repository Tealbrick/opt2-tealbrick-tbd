import Foundation

/// What the Flow observer and the card labeller need from a model: one system text, one user text, an optional JPEG.
public protocol TBDFlowModelCompleting: Sendable {
    func complete(system: String, userText: String, imageJPEG: Data?, config: TBDModelConfig, timeout: TimeInterval) async throws -> String
}

public enum TBDFlowModelError: Error, LocalizedError, Equatable {
    /// The endpoint answered with an error status. The text is the body, with the key removed.
    case http(Int, String)
    case emptyReply
    /// Nothing answered at the endpoint (a local server that is not running, no network).
    case unreachable(isLocal: Bool)
    case redirected
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)
            return detail.isEmpty ? "The model answered with an error (HTTP \(code))." : "The model answered with an error (HTTP \(code)). \(detail)"
        case .emptyReply: return "The model returned no text."
        case .unreachable(let isLocal): return isLocal ? "Ollama is not running on this Mac." : "The model server does not answer."
        case .redirected: return "The model server sent TBD to another address. TBD did not follow it."
        case .failed(let reason): return reason
        }
    }
}

/// One non-streaming call for the Flow observer, over an OpenAI-compatible or an Anthropic endpoint (C142). The request
/// goes only to the configured base URL: a redirect is refused, so a key is never sent to another host. An error text
/// never holds the key.
public struct TBDFlowModelClient: TBDFlowModelCompleting {
    public static let maxTokens = 1200
    public static let temperature = 0.1
    private let session: URLSession

    public init(session: URLSession = TBDFlowModelClient.makeSession()) { self.session = session }

    /// A session that keeps nothing: no cookies, no cache, no stored credentials.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    public func complete(system: String, userText: String, imageJPEG: Data?, config: TBDModelConfig, timeout: TimeInterval) async throws -> String {
        let request = try Self.makeRequest(system: system, userText: userText, imageJPEG: imageJPEG, config: config, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request, delegate: NoRedirect())
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                if (300..<400).contains(code) { throw TBDFlowModelError.redirected }
                throw TBDFlowModelError.http(code, Self.scrub(String(decoding: data, as: UTF8.self), key: config.apiKey))
            }
            let text = try TBDChatClient.parse(data, kind: config.kind)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TBDFlowModelError.emptyReply }
            return text
        } catch let error as TBDFlowModelError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                throw TBDFlowModelError.unreachable(isLocal: config.isLocal)
            case .httpTooManyRedirects:
                throw TBDFlowModelError.redirected
            case .timedOut:
                throw TBDFlowModelError.failed("The model did not answer in time.")
            default:
                throw TBDFlowModelError.failed(Self.scrub(error.localizedDescription, key: config.apiKey))
            }
        } catch {
            throw TBDFlowModelError.failed(Self.scrub(error.localizedDescription, key: config.apiKey))
        }
    }

    /// The request for one call. Public so the tests (and the debug panel) can read it.
    public static func makeRequest(system: String, userText: String, imageJPEG: Data?, config: TBDModelConfig,
                                   timeout: TimeInterval) throws -> URLRequest {
        var request: URLRequest
        var body: [String: Any] = ["model": config.model, "max_tokens": maxTokens, "temperature": temperature]
        switch config.kind {
        case .openAICompatible:
            request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
            var content: Any = userText
            if let imageJPEG {
                content = [["type": "text", "text": userText],
                           ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + imageJPEG.base64EncodedString()]]] as [[String: Any]]
            }
            body["messages"] = [["role": "system", "content": system], ["role": "user", "content": content]] as [[String: Any]]
            if let key = config.apiKey, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            request = URLRequest(url: config.baseURL.appendingPathComponent("v1/messages"))
            body["system"] = system
            var blocks: [[String: Any]] = []
            if let imageJPEG {
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageJPEG.base64EncodedString()]])
            }
            blocks.append(["type": "text", "text": userText])
            body["messages"] = [["role": "user", "content": blocks]] as [[String: Any]]
            if let key = config.apiKey, !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// `text` without the key (an endpoint may echo a bad key back in its error body).
    static func scrub(_ text: String, key: String?) -> String {
        guard let key, key.count >= 4 else { return text }
        return text.replacingOccurrences(of: key, with: "[key removed]")
    }

    /// Refuses every redirect (the answer stays a 3xx and becomes `.redirected`).
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
