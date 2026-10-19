import AppKit
import SwiftUI
import TBDModels
import WebKit
import Security
import UserNotifications
import TBDDesign
import TBDListening

@MainActor
final class TBDChatRuntime: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
  static let shared = TBDChatRuntime()
  @Published private(set) var status = "Starting Chat"
  /// Transient, non-blocking notice shown over Chat (e.g. after an automatic helper restart).
  @Published private(set) var notice = ""
  let webView: WKWebView
  private var process: Process?
  private var input: FileHandle?
  private var generation = UUID()
  private var ready = false
  private var queued: [[String: Any]] = []
  private var outstanding = Set<Int>()
  private var hostRequestID = -100
  private var hostRequests: [Int: CheckedContinuation<Any, Error>] = [:]
  private var resetRequest: Int?
  private var key = ""
  private var started = false
  private var stopping = false
  private var lastAutoRestart: Date?
  private var reloadOnReady = false

  private var appearanceName = "light"

  /// Chat reads every colour from its generated kit tokens (tbd-tokens.css); the host only says light or dark.
  func updateAppearance(dark: Bool) {
    appearanceName = dark ? "dark" : "light"
    webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    applyAppearance()
  }
  private func applyAppearance() {
    webView.evaluateJavaScript("document.documentElement.dataset.theme='\(appearanceName)';document.documentElement.style.colorScheme='\(appearanceName)';", completionHandler: nil)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { applyAppearance() }

  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    config.userContentController.addUserScript(WKUserScript(source: "window.addEventListener('error', e => window.webkit.messageHandlers.tbd.postMessage({id:-1,channel:'tbd:renderError',args:[e.message || 'Chat asset failed to load']}));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
    config.userContentController.add(self, name: "tbd")
    webView.navigationDelegate = self
  }

  func start() {
    guard !started else { return }; started = true
    #if DEBUG
      // `--design-shots` renders screens only: no Chat helper, no sign-in, no network.
      if TBDIdentity.isDesignShots { status = "Chat is off in design shots."; return }
    #endif
    do {
      key = try credentialKey().base64EncodedString()
      try startHelper()
      guard let root = Bundle.main.resourceURL?.appendingPathComponent("Chat/renderer"),
        FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path)
      else { throw failure("Chat assets are missing. Run scripts/build.sh.") }
      webView.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
    } catch { status = error.localizedDescription }
  }

  // Native settings use the same IPC handlers and credential store as Chat.
  func accountCall(_ channel: String, args: [Any] = []) async throws -> Any {
    let allowed: Set<String> = ["session", "controlPlanes", "portalWorkspaces", "selectPortalWorkspace", "signIn", "awaitSignIn", "cancelSignIn", "signOut", "activateControlPlane", "addControlPlane", "removeControlPlane",
      // Read-only: agent directory (TBD agent) and the verified update feed for the native updater.
      "listAgents", "checkUpdate",
      // First-launch onboarding (WP-ONB step 2): pair TBD's agent card with the workspace (browser approves).
      "agentConnection", "agentConnect", "awaitAgentConnect", "cancelAgentConnect"]
    guard allowed.contains(channel) else { throw failure("Unsupported account operation") }
    start()
    guard ready || process?.isRunning == true else { throw failure(status) }
    return try await hostCall(channel, args: args, timeout: .seconds(["awaitSignIn", "awaitAgentConnect"].contains(channel) ? 660 : 45),
                              timeoutMessage: "Portal operation timed out. Refresh to check current state.")
  }

  /// Progress handlers of running "Save to Knowledge" requests, by transcript id.
  private var knowledgeStatus: [String: @MainActor (String) -> Void] = [:]

  /// Listening "Save to Knowledge" (WP10): the helper calls Knowledge as TBD's own agent (key
  /// connection and local relay), never with the person's token. Holds can take minutes.
  func knowledgeSave(_ request: TBDKnowledgeSaveRequest, onStatus: @escaping @MainActor (String) -> Void) async throws -> TBDKnowledgeSaveResult {
    start()
    guard ready || process?.isRunning == true else { throw TBDKnowledgeError.signIn }
    knowledgeStatus[request.transcriptId] = onStatus
    defer { knowledgeStatus[request.transcriptId] = nil }
    let value = try await hostCall("knowledgeSave", args: [request.payload], timeout: .seconds(11 * 60),
                                   timeoutMessage: "Knowledge did not answer in time. Try again.")
    guard let result = TBDKnowledgeSaveResult(payload: value) else { throw failure("Knowledge did not return a document id. Try again.") }
    return result
  }

  /// One native-originated helper request (negative ids, `hostRequests`), with a time limit.
  private func hostCall(_ channel: String, args: [Any], timeout: Duration, timeoutMessage: String) async throws -> Any {
    hostRequestID -= 1
    let id = hostRequestID
    return try await withCheckedThrowingContinuation { continuation in
      hostRequests[id] = continuation
      outstanding.insert(id)
      let message: [String: Any] = ["id": id, "channel": "studio:" + channel, "args": args]
      if ready { send(message) } else { queued.append(message) }
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: timeout)
        guard let self, self.hostRequests[id] != nil else { return }
        self.reply(id, error: timeoutMessage)
      }
    }
  }

  func reloadAccountUI() { webView.reload() }

  private func startHelper() throws {
    guard let resources = Bundle.main.resourceURL else { throw failure("Missing bundle resources") }
    let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    let current = UUID(); generation = current; ready = false
    p.executableURL = resources.appendingPathComponent("Chat/node")
    p.arguments = [resources.appendingPathComponent("Chat/helper.cjs").path]
    let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/" + TBDIdentity.dataFolder + "/Chat")
    try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    // Isolation: the helper gets an allow-listed environment, never the app's.
    let inherited = ProcessInfo.processInfo.environment
    var env: [String: String] = ["TBD_CHAT_DATA": data.path, "HOME": inherited["HOME"] ?? NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
    for key in ["TMPDIR", "LANG", "LC_ALL", "TBD_PORTAL_URL", "TBD_CHAT_DEBUG_STREAM"] { if let v = inherited[key] { env[key] = v } }
    // Paths the default agent needs: its bundle and the harness-local tool CLIs (C5).
    env["TBD_RESOURCES"] = resources.appendingPathComponent("Chat").path
    // TBD's agent works NEXT to the app's data ("<dataFolder>-agent"; chat/src/main/appIdentity.ts agentFolder), never
    // inside it, so the data folder stays fully denied to the agent's sandbox; never the archived v1 agent folder (C284).
    env["TBD_AGENT_WORKSPACE"] = data.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(TBDIdentity.dataFolder + "-agent/Workspace").path
    if let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers") as URL? {
      env["TBD_COMPANION_CLI"] = helpers.appendingPathComponent("dayflow").path
      env["TBD_LISTENING_CLI"] = helpers.appendingPathComponent("tbd-listen").path
    }
    #if DEBUG
      if TBDIdentity.isDev {
        // TBD Dev: TBD_CHAT_DATA and the agent workspace above are already under <dataFolder>-dev. The bundled CLIs
        // are release builds that read the live app's data, so the dev helper gets none. The helper's file policy keeps
        // denying the live folder.
        env["TBD_COMPANION_CLI"] = nil
        env["TBD_LISTENING_CLI"] = nil
      }
    #endif
    p.environment = env
    p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
    let reader = TBDLineReader()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let bytes = handle.availableData
      for line in reader.append(bytes) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
        Task { @MainActor in
          guard let self, self.generation == current else { return }
          self.receive(object)
        }
      }
    }
    // Persist only redacted error lines; the rest of the diagnostic output is dropped.
    let errors = TBDLineReader()
    stderr.fileHandleForReading.readabilityHandler = { handle in
      for line in errors.append(handle.availableData) { TBDHelperLog.shared.record(line) }
    }
    p.terminationHandler = { [weak self] ended in
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      Task { @MainActor in
        guard let self, self.generation == current else { return }
        self.ready = false
        if let request = self.resetRequest, !self.stopping {
          do { try self.startHelper(); self.resetRequest = request }
          catch { self.failOutstanding(error.localizedDescription) }
        } else if !self.stopping {
          let code = ended.terminationStatus
          TBDHelperLog.shared.note("helper exited (\(ended.terminationReason == .uncaughtSignal ? "signal" : "status") \(code))")
          // Restart once automatically; a second exit within ten minutes is a crash loop and stays visible.
          if self.lastAutoRestart.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
            self.lastAutoRestart = Date()
            self.failOutstanding("Chat restarted after an error. Try again.")
            do {
              try self.startHelper(); self.reloadOnReady = true
              self.show(notice: "Chat restarted after an error. Details: ~/Library/Logs/\(TBDIdentity.dataFolder)/chat-helper.log")
              return
            } catch { TBDHelperLog.shared.note("helper restart failed") }
          }
          self.status = "Chat transport stopped (\(code)). Details: ~/Library/Logs/\(TBDIdentity.dataFolder)/chat-helper.log"
          self.failOutstanding(self.status)
        }
      }
    }
    try p.run(); process = p; input = stdin.fileHandleForWriting
    send(["type": "init", "key": key])
  }

  private func receive(_ message: [String: Any]) {
    switch message["type"] as? String {
    case "fatal":
      status = message["error"] as? String ?? "Chat initialization failed"
      failOutstanding(status)
    case "ready":
      ready = true; status = ""
      // After an automatic restart, reload so the page re-attaches its streams to the new helper.
      if reloadOnReady { reloadOnReady = false; webView.reload() }
      if let id = resetRequest { resetRequest = nil; reply(id, value: NSNull()); if id < -100 { reloadAccountUI() } }
      let waiting = queued; queued.removeAll(); for item in waiting { send(item) }
    case "reset":
      guard let id = message["id"] as? Int else { return }
      resetRequest = id; ready = false
      // Cancel workspace-bound Chat dictation; Listening meetings and Companion capture stay alive.
      Task { _ = try? await TBDListeningRuntime.shared.chatAudio("cancel") }
      // Invalidate all callbacks from the previous scope before restarting only the helper.
      for pending in Array(outstanding) where pending != id { reply(pending, error: "Chat workspace changed") }
      queued.removeAll()
      send(["type": "shutdown"])
    case "native":
      guard let id = message["id"] as? Int, let method = message["method"] as? String else { return }
      let epoch = generation
      Task {
        do {
          let value = try await native(method, args: message["args"] as? [Any] ?? [])
          guard generation == epoch else { return }
          send(["type": "nativeReply", "id": id, "value": value])
        } catch {
          guard generation == epoch else { return }
          send(["type": "nativeReply", "id": id, "error": error.localizedDescription])
        }
      }
    case "reply":
      guard resetRequest == nil else { return }
      if let id = message["id"] as? Int, hostRequests[id] != nil {
        reply(id, value: message["value"] ?? NSNull(), error: message["error"] as? String)
      } else {
        if let id = message["id"] as? Int { outstanding.remove(id) }
        deliver(message)
      }
    case "event":
      // "Save to Knowledge" progress goes to Listening, not to the web page.
      if message["channel"] as? String == "tbd:knowledgeSaveStatus" {
        let payload = message["payload"] as? [String: Any]
        if let id = payload?["transcriptId"] as? String, let text = payload?["message"] as? String { knowledgeStatus[id]?(text) }
        return
      }
      if resetRequest == nil { deliver(message) }
    default: break
    }
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
      let body = message.body as? [String: Any], let id = body["id"] as? Int,
      let channel = body["channel"] as? String else { return }
    if channel == "tbd:renderError" { status = (body["args"] as? [String])?.first ?? "Chat failed to render"; return }
    guard id >= 0 else { return } // Negative IDs belong exclusively to native requests.
    outstanding.insert(id)
    if channel == "tbd:audio" {
      let operation = (body["args"] as? [String])?.first ?? ""
      let epoch = generation
      Task {
        do {
          let value = try await TBDListeningRuntime.shared.chatAudio(operation)
          guard generation == epoch, resetRequest == nil else { return }
          reply(id, value: value)
        } catch {
          guard generation == epoch, resetRequest == nil else { return }
          reply(id, error: error.localizedDescription)
        }
      }
      return
    }
    guard channel.hasPrefix("studio:") else { reply(id, error: "Unknown bridge channel"); return }
    if ready { send(body) } else if resetRequest != nil || process?.isRunning == true { queued.append(body) }
    else { reply(id, error: status) }
  }

  private func send(_ message: [String: Any]) {
    guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    do { try input.write(contentsOf: data + Data([10])) }
    catch { failOutstanding("Chat transport unavailable") }
  }
  private func deliver(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message), let json = String(data: data, encoding: .utf8) else { return }
    webView.evaluateJavaScript("window.__tbdReceive && window.__tbdReceive(\(json))", completionHandler: nil)
  }
  private func reply(_ id: Int, value: Any = NSNull(), error: String? = nil) {
    outstanding.remove(id)
    if let continuation = hostRequests.removeValue(forKey: id) {
      if let error { continuation.resume(throwing: failure(error)) }
      else { continuation.resume(returning: value) }
      return
    }
    var message: [String: Any] = ["type": "reply", "id": id, "value": value]
    if let error { message["error"] = error }; deliver(message)
  }
  private func failOutstanding(_ reason: String) {
    for id in Array(outstanding) { reply(id, error: reason) }; queued.removeAll()
  }
  func stop() {
    stopping = true; failOutstanding("TBD is shutting down"); send(["type": "shutdown"])
    try? input?.close(); input = nil
  }
  private func show(notice text: String) {
    notice = text
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(12))
      if self?.notice == text { self?.notice = "" }
    }
  }
  private func failure(_ reason: String) -> NSError { NSError(domain: "TBD.Chat", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }

  private func credentialKey() throws -> Data {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: TBDIdentity.keychainService("chat"), kSecAttrAccount as String: "storage-key"]
    var read = query; read[kSecReturnData as String] = true
    var item: CFTypeRef?
    let result = SecItemCopyMatching(read as CFDictionary, &item)
    if result == errSecSuccess, let data = item as? Data, data.count == 32 { return data }
    guard result == errSecItemNotFound else { throw failure("Unable to unlock Chat credentials (\(result))") }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Unable to create credential key") }
    let data = Data(bytes); var add = query; add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw failure("Unable to store credential key") }
    return data
  }

  /// The "agent" model route; must be an Anthropic connection with a key (Claude Agent SDK).
  /// The error text is what Chat shows on the TBD row and in the composer ("No model set").
  static func agentModel() throws -> TBDModelConfig {
    try TBDAgentModelSetup.resolve(TBDModelRegistry())
  }

  private func native(_ method: String, args: [Any]) async throws -> Any {
    let text = args.first as? String ?? ""
    switch method {
    case "openExternal":
      guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw failure("Invalid external URL") }
      NSWorkspace.shared.open(url); return NSNull()
    case "openPath": return NSWorkspace.shared.open(URL(fileURLWithPath: text)) ? "" : "Unable to open file"
    case "reveal": NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: text)]); return NSNull()
    case "activate": NSApp.activate(ignoringOtherApps: true); return NSNull()
    case "listening": TBDListeningRuntime.shared.activate?(); return NSNull()
    // Chat first-run checks ("No model set", sign-in/workspace): the setup flow at TBD's agent or the workspace step
    // (WP-ONB missing-dependency links). Only these two sections.
    case "openSettings":
      guard ["engine", "account"].contains(text) else { throw failure("Unsupported settings section") }
      NSApp.activate(ignoringOtherApps: true)
      let step: TBDOnboardingStep = text == "engine" ? .agent : .portal
      NotificationCenter.default.post(name: .tbdOpenOnboarding, object: step.rawValue)
      return NSNull()
    case "openDialog":
      let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
      let response = await panel.begin()
      return ["canceled": response != .OK, "filePaths": panel.urls.map(\.path)]
    case "saveDialog":
      let panel = NSSavePanel()
      if let options = args.first as? [String: Any], let path = options["defaultPath"] as? String { panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent }
      let response = await panel.begin()
      return ["canceled": response != .OK, "filePath": panel.url?.path ?? ""]
    case "notify":
      let options = args.first as? [String: String] ?? [:]
      let center = UNUserNotificationCenter.current()
      // Notifications are best effort: denied or unavailable is not an error for Chat.
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return NSNull() }
      let content = UNMutableNotificationContent(); content.title = options["title"] ?? "TBD"; content.body = options["body"] ?? ""
      try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)); return NSNull()
    // TBD's default agent: the model route the person chose for the "agent" task (Settings → Models).
    case "agentModelStatus": _ = try Self.agentModel(); return NSNull()
    // The model id only (agent panel); never the key.
    case "agentModelName": return (try? Self.agentModel())?.model ?? NSNull()
    case "agentModel":
      let config = try Self.agentModel()
      return ["model": config.model, "baseUrl": config.baseURL.absoluteString, "apiKey": config.apiKey ?? ""]
    // Person session (K3): Keychain item tealbrick.person, user presence where available.
    case "personLoad": return try TBDKeychain.personLoad(origin: text) ?? NSNull()
    case "personSave": try TBDKeychain.personSave(origin: text, value: args.dropFirst().first as? String ?? ""); return NSNull()
    case "personClear": try TBDKeychain.personClear(origin: text); return NSNull()
    // Agent key (K4): the private key stays in the Keychain; the helper only gets public keys and signatures.
    case "agentKeyCreate": return try TBDAgentKeys.create(label: text)
    case "agentKeyPublic": return try TBDAgentKeys.publicJwk(label: text)
    case "agentKeySign": return try TBDAgentKeys.sign(label: text, signingInput: args.dropFirst().first as? String ?? "")
    case "agentKeyRename": return try { try TBDAgentKeys.rename(from: text, to: args.dropFirst().first as? String ?? ""); return NSNull() }()
    case "agentKeyDelete": return try { try TBDAgentKeys.delete(label: text); return NSNull() }()
    default: throw failure("Unsupported native operation: \(method)")
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
    if url.isFileURL, let root = Bundle.main.resourceURL?.appendingPathComponent("Chat/renderer").standardizedFileURL.path,
      url.standardizedFileURL.path.hasPrefix(root + "/") { decisionHandler(.allow) }
    else { if ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }; decisionHandler(.cancel) }
  }
}

/// Redacted, error-only log of the Chat helper's stderr at ~/Library/Logs/<dataFolder>/chat-helper.log.
/// Never records tokens or message content: only error lines, redacted and truncated.
final class TBDHelperLog: @unchecked Sendable {
  static let shared = TBDHelperLog()
  private let queue = DispatchQueue(label: "com.tealbrick.desktop.chat-helper-log")
  private let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/" + TBDIdentity.dataFolder + "/chat-helper.log")
  private static let errorLine = try! NSRegularExpression(pattern: #"\[helper:error\]|\b[A-Za-z]*Error\b|[Uu]nhandled|[Uu]ncaught|\bfatal\b|^Node\.js v"#)
  private static let redactions: [(NSRegularExpression, String)] = [
    (#"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.?[A-Za-z0-9_-]*"#, "[jwt]"),
    (#"(?i)\b(bearer|basic)\s+\S+"#, "$1 [redacted]"),
    (#"(?i)\b(token|refresh_token|access_token|secret|password|api[_-]?key|authorization|cookie|key|bundle)(["']?\s*[:=]\s*["']?)[^\s"',}&]+"#, "$1$2[redacted]"),
    (#"\?[^\s"')]+"#, "?[query]"),
    // Long opaque runs mixing letters and digits (keys, tokens); digit-free paths stay readable.
    (#"(?=[A-Za-z0-9+/_=-]*\d)(?=[A-Za-z0-9+/_=-]*[A-Za-z])[A-Za-z0-9+_=-][A-Za-z0-9+/_=-]{31,}"#, "[redacted]"),
  ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

  static func redact(_ text: String) -> String {
    var out = String(text.prefix(600))
    for (pattern, template) in redactions {
      out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
    }
    return out
  }
  /// One stderr line from the helper; kept only when it describes an error.
  func record(_ line: Data) {
    guard let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
      Self.errorLine.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return }
    write(Self.redact(text))
  }
  /// A host-side event (no helper output involved).
  func note(_ text: String) { write("[host] " + text) }
  private func write(_ text: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    queue.async { [url] in
      let fm = FileManager.default
      try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 {
        let old = url.appendingPathExtension("1"); try? fm.removeItem(at: old); try? fm.moveItem(at: url, to: old)
      }
      if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("\(stamp) \(text)\n".utf8))
    }
  }
}

private final class TBDLineReader: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  func append(_ data: Data) -> [Data] {
    lock.lock(); defer { lock.unlock() }; buffer.append(data)
    var lines: [Data] = []
    while let end = buffer.firstIndex(of: 10) { lines.append(buffer[..<end]); buffer.removeSubrange(...end) }
    return lines
  }
}

struct TBDChatView: NSViewRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  func makeNSView(context: Context) -> WKWebView {
    TBDChatRuntime.shared.updateAppearance(dark: colorScheme == .dark)
    TBDChatRuntime.shared.start()
    return TBDChatRuntime.shared.webView
  }
  func updateNSView(_ nsView: WKWebView, context: Context) {
    TBDChatRuntime.shared.updateAppearance(dark: colorScheme == .dark)
  }
}
