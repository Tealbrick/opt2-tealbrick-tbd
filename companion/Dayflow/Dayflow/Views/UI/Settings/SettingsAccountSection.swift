import TBDDesign
import SwiftUI

/// Presentation only. Tokens, refresh and issuer/workspace isolation stay in Chat's transport.
@MainActor
final class TBDAccountCoordinator: ObservableObject {
  static let shared = TBDAccountCoordinator()
  @Published private(set) var email = ""
  @Published private(set) var signedIn = false
  @Published private(set) var hasCheckedSession = false
  @Published private(set) var status = "Connecting to Portal session…"
  @Published private(set) var error = ""
  @Published private(set) var busy = false
  @Published private(set) var code = ""
  @Published private(set) var profiles: [PortalChoice] = []
  @Published private(set) var workspaces: [PortalChoice] = []
  @Published private(set) var activeProfile = ""
  @Published private(set) var activeWorkspace = ""
  private var refreshing = false
  private var revision = 0

  struct PortalChoice: Identifiable {
    let id: String
    let name: String
    var issuer = ""
  }
  private func call(_ name: String, _ args: [Any] = []) async throws -> Any {
    try await TBDChatRuntime.shared.accountCall(name, args: args)
  }
  func refresh(workspace: Bool = false) async {
    guard !refreshing, !busy else { return }
    refreshing = true
    let epoch = revision
    defer { refreshing = false }
    do {
      let registry = try await call("controlPlanes") as? [String: Any] ?? [:]
      let session = try await call("session") as? [String: Any]
      guard epoch == revision else { return }
      let nextProfile = registry["activeId"] as? String ?? ""
      let profileChanged = activeProfile != nextProfile
      activeProfile = nextProfile
      profiles = (registry["profiles"] as? [[String: Any]] ?? []).compactMap {
        guard let id = $0["id"] as? String, let name = $0["name"] as? String else { return nil }
        return PortalChoice(id: id, name: name, issuer: $0["issuer"] as? String ?? "")
      }
      let changed = email != (session?["email"] as? String ?? "") || signedIn != (session != nil)
      signedIn = session != nil
      hasCheckedSession = true
      email = session?["email"] as? String ?? ""
      let expired = (session?["expiresAt"] as? Double ?? 0) < Date().timeIntervalSince1970 * 1000
      status = signedIn ? (expired ? "Session saved · refresh needed" : "Signed in") : "Signed out"
      error = ""
      if !signedIn { workspaces = []; activeWorkspace = "" }
      else if workspace || changed || profileChanged {
        workspaces = []; activeWorkspace = ""
        let directory = try await call("portalWorkspaces") as? [String: Any] ?? [:]
        guard epoch == revision else { return }
        workspaces = (directory["workspaces"] as? [[String: String]] ?? []).compactMap {
          guard let id = $0["id"], let name = $0["name"] else { return nil }
          return PortalChoice(id: id, name: name)
        }
        activeWorkspace = directory["selectedId"] as? String ?? ""
      }
    } catch {
      guard epoch == revision else { return }
      self.error = error.localizedDescription
      status = "Portal status unavailable · retry"
    }
  }
  func perform(_ name: String, args: [Any] = []) async {
    guard !busy else { return }
    revision += 1
    busy = true; error = ""
    do { _ = try await call(name, args) }
    catch { self.error = error.localizedDescription }
    let actionError = error
    busy = false
    await refresh(workspace: true)
    if !actionError.isEmpty { error = actionError }
  }
  func signIn() async {
    guard !busy else { return }
    revision += 1; let epoch = revision
    busy = true; error = ""
    do {
      let started = try await call("signIn") as? [String: Any] ?? [:]
      guard epoch == revision else { return }
      code = started["userCode"] as? String ?? ""
      _ = try await call("awaitSignIn")
      guard epoch == revision else { return }
      TBDChatRuntime.shared.reloadAccountUI()
    } catch {
      guard epoch == revision else { return }
      self.error = error.localizedDescription
    }
    let actionError = error
    code = ""; busy = false
    await refresh(workspace: true)
    if !actionError.isEmpty { error = actionError }
  }
  func cancel() async {
    revision += 1
    _ = try? await call("cancelSignIn")
    code = ""; busy = false
    await refresh()
  }
}

struct SettingsAccountSection: View {
  @ObservedObject private var account = TBDAccountCoordinator.shared
  @State private var portalName = ""
  @State private var portalURL = ""

  private var statusState: SettingsStatusDot.State {
    if account.signedIn { return account.status == "Signed in" ? .good : .warn }
    return account.error.isEmpty ? .idle : .warn
  }

  private var workspaceName: String {
    account.workspaces.first(where: { $0.id == account.activeWorkspace })?.name ?? ""
  }

  /// "alex.rivera@…" gives "AR"; one name part gives its first letter.
  private var initials: String {
    let local = account.email.split(separator: "@").first.map(String.init) ?? ""
    let parts = local.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    let letters = parts.count > 1 ? [parts[0], parts[1]].compactMap(\.first) : parts.first.flatMap(\.first).map { [$0] } ?? []
    return letters.isEmpty ? "?" : String(letters).uppercased()
  }

  /// Profile block: the ink brick avatar (44pt, primary pair) beside the email and the workspace.
  private var profileBlock: some View {
    HStack(spacing: TBDKit.s4) {
      Text(initials)
        .font(TBDFonts.nunito(TBDKit.textControl, TBDKit.weightLabel))
        .foregroundStyle(TBDColor.primaryOn)
        .frame(width: TBDKit.target, height: TBDKit.target)
        .background(TBDColor.primaryFill, in: TBDBrickShape())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(account.email)
          .font(TBDTokens.Typography.control)
          .foregroundStyle(TBDColor.ink)
          .textSelection(.enabled)
        if account.signedIn, !workspaceName.isEmpty {
          Text(workspaceName)
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
        }
      }
    }
  }

  private var ruled: some View {
    Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
  }

  var body: some View {
    SettingsSection(title: "", isFirst: true) {
      VStack(alignment: .leading, spacing: TBDKit.s4) {
        SettingsStatusDot(state: statusState, label: account.status)
        if !account.email.isEmpty {
          profileBlock
        }
        ruled
        SettingsRow(label: String(localized: "Portal"), showsDivider: false) {
          if account.profiles.isEmpty {
            // The list comes from the Chat helper; without it an empty picker looked broken (TBD-UX-01).
            Text("Not loaded. Use Refresh status.")
              .font(TBDTokens.Typography.hint)
              .foregroundStyle(TBDColor.muted)
          } else {
            Picker("Portal", selection: Binding(get: { account.activeProfile }, set: { id in
              Task { await account.perform("activateControlPlane", args: [id]) }
            })) {
              ForEach(account.profiles) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .disabled(account.signedIn || account.busy)
          }
        }
        if let profile = account.profiles.first(where: { $0.id == account.activeProfile }) {
          Text(profile.issuer)
            .font(TBDFonts.mono(TBDKit.textHint))
            .foregroundStyle(TBDColor.muted)
            .textSelection(.enabled)
        }
        if account.signedIn {
          ruled
          SettingsRow(label: String(localized: "Workspace"), showsDivider: false) {
            Picker("Workspace", selection: Binding(get: { account.activeWorkspace }, set: { id in
              guard !id.isEmpty else { return }
              Task { await account.perform("selectPortalWorkspace", args: [id]) }
            })) {
              Text("Select workspace").tag("")
              ForEach(account.workspaces) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
            .disabled(account.busy)
          }
          ruled
          Button("Sign out") { Task { await account.perform("signOut") } }
            .buttonStyle(TBDButtonStyle(.destructive))
            .disabled(account.busy)
          Text("Sign out before changing Portal.")
            .font(TBDTokens.Typography.hint)
            .foregroundStyle(TBDColor.muted)
        } else if account.busy {
          if !account.code.isEmpty {
            Text(account.code)
              .font(TBDFonts.mono(TBDKit.textH2, TBDKit.weightLabel))
              .foregroundStyle(TBDColor.ink)
              .textSelection(.enabled)
            Button("Cancel sign-in") { Task { await account.cancel() } }
              .buttonStyle(TBDButtonStyle(.secondary))
          } else { ProgressView() }
        } else {
          Button("Sign in") { Task { await account.signIn() } }
            .buttonStyle(TBDButtonStyle(.primary))
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
              TextField("Name", text: $portalName).tbdField()
              TextField("https://portal.example.com", text: $portalURL).tbdField()
              Button("Add Portal") {
                Task { await account.perform("addControlPlane", args: [["name": portalName, "issuer": portalURL]]) }
              }
              .buttonStyle(TBDButtonStyle(.secondary))
              .disabled(portalName.trimmingCharacters(in: .whitespaces).isEmpty || portalURL.isEmpty)
            }.padding(.top, 8)
          } label: {
            Text("Self-hosted Portal")
              .font(TBDTokens.Typography.control)
              .foregroundStyle(TBDColor.ink)
          }
        }
        Button("Refresh status") { Task { await account.refresh(workspace: true) } }
          .buttonStyle(TBDButtonStyle(.quiet))
          .disabled(account.busy)
        if !account.error.isEmpty {
          TBDNotice(account.error, tone: .needsYou)
        }
        Rectangle().fill(TBDColor.line).frame(height: TBDKit.hair)
        Text("Portal sign-in enables Chat and remote agents. Companion and Listen work without an account. macOS permissions are managed separately in Access.")
          .font(TBDTokens.Typography.hint)
          .foregroundStyle(TBDColor.muted)
      }
    }
    .task {
      await account.refresh(workspace: true)
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        await account.refresh()
      }
    }
  }
}
