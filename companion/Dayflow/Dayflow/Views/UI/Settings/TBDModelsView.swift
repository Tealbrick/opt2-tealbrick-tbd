import TBDDesign
import TBDListening
import TBDModels
import SwiftUI

struct TBDModelsView: View {
  let screenSettings: () -> AnyView
  init(screenSettings: @escaping () -> AnyView, initialPage: String = "Tasks") {
    self.screenSettings = screenSettings
    _page = State(initialValue: initialPage)
  }
  @State private var state = TBDModelRegistryState()
  @State private var page: String
  @State private var name = ""
  @State private var endpoint = ""
  @State private var secret = ""
  @State private var kind: TBDModelKind = .openAICompatible
  @State private var error = ""
  @AppStorage(TBDCleanupPolicy.chatKey) private var chatCleanup = false
  @AppStorage(TBDCleanupPolicy.voiceNoteKey) private var noteCleanup = false
  private let registry = TBDModelRegistry()

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      TBDSegmented(selection: $page, options: TBDSettingsRoute.modelsPages.map { ($0, $0) })
      switch page {
      case "Transcription":
        Text("Speech recognition runs locally. Select engines and downloads below.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
        TBDListeningRuntime.shared.settingsContent(section: "engine")
      case "Advanced":
        // One scroll for the page: the providers block can be long when opened (TBD-UX-01 review).
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 18) {
            Text("Existing provider-specific settings remain available. Shared task routes take precedence when assigned.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
            DisclosureGroup { screenSettings() } label: { Text("Screen analysis providers").font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink) }
            TBDListeningRuntime.shared.settingsContent(section: "ai", scrolls: false)
          }
        }
      default:
        ScrollView(.vertical, showsIndicators: false) {
          VStack(alignment: .leading, spacing: 22) {
            if page == "Connections" { connections }
            else {
              Text("Set up a connection once, then choose it for each task below. Choosing a model does not turn on cleanup. TBD never moves a task to another provider by itself.")
                .font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
              TBDAgentModelForm { reload() }
              route("Cleanup", task: "cleanup", detail: "Optional transcript correction; shared model, independent switches.")
              Toggle("Clean up Chat voice input", isOn: $chatCleanup).toggleStyle(TBDSwitchStyle()).frame(maxWidth: 420)
              Toggle("Clean up voice notes", isOn: $noteCleanup).toggleStyle(TBDSwitchStyle()).frame(maxWidth: 420)
              Text("Both are off by default. Raw text is retained; a cleanup failure returns raw text. Voice notes are saved to history. Chat follows your dictation-history preference. Cleanup may send text to the selected network provider.").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
              route("Summaries", task: "analysis", detail: "Meeting and transcript analysis.")
              route("Transforms", task: "general", detail: "Text transformations and the default Listen AI route.")
              route("Screen analysis", task: "screen", detail: "Companion activity analysis. Choose a vision-capable model; screenshots may leave this Mac.")
            }
            if !error.isEmpty { TBDNotice(error, tone: .needsYou) }
          }.padding(.bottom, 24)
        }
      }
    }
    .onAppear { reload() }
  }
  private var connections: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("OpenAI-compatible or Anthropic endpoints. Keys are held in Keychain and reused only by routes assigned to that connection. Existing provider configurations remain unchanged until you assign a shared route.").font(TBDTokens.Typography.body).foregroundStyle(TBDColor.inkSoft)
      ForEach(state.connections) { connection in
        VStack(alignment: .leading) {
          Text(connection.name).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
          Text("\(connection.kind == .anthropic ? "Anthropic" : "OpenAI-compatible") · \(connection.endpoint)").font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted).textSelection(.enabled)
        }
        Divider()
      }
      TBDSegmented(selection: $kind, options: [(TBDModelKind.openAICompatible, "OpenAI-compatible"), (TBDModelKind.anthropic, "Anthropic")])
      .onChange(of: kind) { _, k in if k == .anthropic && endpoint.isEmpty { endpoint = "https://api.anthropic.com" } }
      TextField("Connection name", text: $name).tbdField()
      TextField("https://host.example/v1", text: $endpoint).tbdField()
      SecureField("API key (optional for local servers)", text: $secret).tbdField()
      Button("Save connection") {
        do {
          try registry.saveConnection(TBDModelConnection(name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind), apiKey: secret.isEmpty ? nil : secret)
          secret = ""; name = ""; endpoint = ""; reload()
        } catch { self.error = error.localizedDescription }
      }
      .buttonStyle(TBDButtonStyle(.primary))
      .disabled(name.isEmpty || endpoint.isEmpty)
    }
  }
  private func route(_ title: String, task: String, detail: String) -> some View {
    TBDModelRouteCard(title: title, detail: detail, connections: state.connections, route: state.routes[task]) { route in
      do { try registry.assign(route, to: task); reload() }
      catch { self.error = error.localizedDescription }
    }
  }
  private func reload() {
    do { state = try registry.load(); error = "" }
    catch { self.error = error.localizedDescription }
  }
}

private struct TBDModelRouteCard: View {
  let title: String
  let detail: String
  let connections: [TBDModelConnection]
  let route: TBDModelRoute?
  let save: (TBDModelRoute?) -> Void
  @State private var connectionID = ""
  @State private var model = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(TBDTokens.Typography.control).foregroundStyle(TBDColor.ink)
      Text(detail).font(TBDTokens.Typography.hint).foregroundStyle(TBDColor.muted)
      TBDSelect("Connection", selection: $connectionID, options: [("", "Existing configuration")] + connections.map { ($0.id, $0.name) })
        .frame(maxWidth: 360)
      if !connectionID.isEmpty {
        TextField("Model ID", text: $model).tbdField()
        if let c = connections.first(where: { $0.id == connectionID }) {
          Text(c.endpoint).font(TBDFonts.mono()).foregroundStyle(TBDColor.muted)
        }
      }
      Button("Apply") { save(connectionID.isEmpty ? nil : TBDModelRoute(connectionID: connectionID, model: model.trimmingCharacters(in: .whitespacesAndNewlines))) }
        .buttonStyle(TBDButtonStyle(.secondary))
        .disabled(!connectionID.isEmpty && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Divider()
    }
    .onAppear { connectionID = route?.connectionID ?? ""; model = route?.model ?? "" }
  }
}
