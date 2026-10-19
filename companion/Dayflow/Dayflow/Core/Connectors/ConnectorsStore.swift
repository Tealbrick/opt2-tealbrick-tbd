//
//  ConnectorsStore.swift
//  TBD
//
//  Settings › Connectors (dev.16, C280 C11, DESIGN-CONNECTORS §1, §4). What the pane shows: the gate (plan, agent
//  connection, grant), the accounts Connect lets TBD's agent use, and the person's remembered choices. Every read goes
//  through the Chat helper: `entitlements` and `agentConnection` (as everywhere), `connectAccounts` (TBD's own agent
//  through the local relay; never the person's token) and `connectConsentList` / `connectConsentRevoke` (a local file).
//
//  Refresh: when the pane appears, every 5 minutes while it is visible, when the app gets focus, and after a workspace or
//  account change. Never while the pane or its window is not visible, never while a refresh is running (no overlap).
//  Signed out: no helper call at all. An answer belongs to one account (signed in, workspace, profile, issuer, email);
//  when the account differs, the old names are dropped before the new call answers (no stale names).
//

import AppKit
import Combine
import Foundation
import TBDModels

/// What the pane needs from the helper. The live one is `ConnectorsLiveClient`; tests use a fake.
@MainActor
protocol ConnectorsClient {
  /// The plan's answer for Connect in the active workspace; `.unknown` when it cannot be read.
  func access() async -> TBDAppAccess
  func agentConnected() async -> Bool
  /// Throws the helper's plain sentence (timeout, pause, app error).
  func accounts() async throws -> TBDConnectorAccounts
  /// The remembered choices of the workspace TBD's agent is connected to (a local file).
  func choices() async throws -> [TBDConnectorChoice]
  /// Forgets one choice; returns the list that is left.
  func revoke(account: String, tool: String) async throws -> [TBDConnectorChoice]
}

@MainActor
struct ConnectorsLiveClient: ConnectorsClient {
  func access() async -> TBDAppAccess {
    guard TBDAccountCoordinator.shared.signedIn else { return .locked }
    let value = try? await TBDChatRuntime.shared.accountCall("entitlements")
    return TBDEntitlements(helperValue: value).access(.connect)
  }

  func agentConnected() async -> Bool {
    guard TBDAccountCoordinator.shared.signedIn else { return false }
    let value = try? await TBDChatRuntime.shared.accountCall("agentConnection") as? [String: Any]
    return value?["connected"] as? Bool ?? false
  }

  func accounts() async throws -> TBDConnectorAccounts {
    let value = try await TBDChatRuntime.shared.accountCall("connectAccounts")
    guard let accounts = TBDConnectorAccounts(helperValue: value) else {
      throw NSError(domain: "TBD.Connectors", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect gave an answer TBD does not understand. Try again."])
    }
    return accounts
  }

  func choices() async throws -> [TBDConnectorChoice] {
    TBDConnectorChoice.list(helperValue: try await TBDChatRuntime.shared.accountCall("connectConsentList"))
  }

  func revoke(account: String, tool: String) async throws -> [TBDConnectorChoice] {
    TBDConnectorChoice.list(helperValue: try await TBDChatRuntime.shared.accountCall("connectConsentRevoke", args: [["account": account, "tool": tool]]))
  }
}

/// Everything the pane draws.
struct ConnectorsState: Equatable {
  var gate: TBDConnectorsGate
  /// The accounts of the last good check. Empty unless the gate is `.active`.
  var accounts: [TBDConnectorAccount] = []
  /// The remembered choices. Empty until the first answer for this account.
  var choices: [TBDConnectorChoice] = []
  /// A failed refresh while the last answer is still shown (the list stays, the sentence says why it may be old).
  var notice: String?
  /// The first answer for this account arrived.
  var loaded = false

  static func initial(signedIn: Bool) -> ConnectorsState { ConnectorsState(gate: signedIn ? .checking : .signedOut) }
}

@MainActor
final class ConnectorsStore: ObservableObject {
  static let shared = ConnectorsStore()
  /// Re-read period while the pane is visible.
  static let interval: TimeInterval = 5 * 60

  @Published private(set) var state: ConnectorsState

  private let client: ConnectorsClient
  private let accountNow: () -> AgentWallAccountKey
  private let isAppActive: () -> Bool
  private var timer: Timer?
  private var subscriptions = Set<AnyCancellable>()
  private var inFlight = false
  /// The account of the answer in `state`.
  private var answerKey: AgentWallAccountKey
  /// The pane is on screen. The helper is asked only then.
  private(set) var pageVisible = false
  /// The hosting window is on screen (not minimised, not hidden). The helper is asked only then.
  private(set) var windowVisible = true
  /// Design shots and tests seed a state and never ask the helper.
  private(set) var frozen = false
  /// Refreshes that reached the helper (tests).
  private(set) var refreshCount = 0
  /// Bumped by a revoke: a refresh that started before it must not bring the forgotten choice back.
  private var choicesRevision = 0

  init(client: ConnectorsClient? = nil, account: (() -> AgentWallAccountKey)? = nil, isAppActive: (() -> Bool)? = nil) {
    self.client = client ?? ConnectorsLiveClient()
    accountNow = account ?? { TBDAccountCoordinator.shared.wallKey }
    self.isAppActive = isAppActive ?? { NSApplication.shared.isActive }
    let key = accountNow()
    answerKey = key
    state = .initial(signedIn: key.signedIn)
  }

  /// The 5-minute timer runs (only while the pane and its window are visible).
  var isPolling: Bool { timer != nil }
  var isRefreshing: Bool { inFlight }
  private var canRead: Bool { pageVisible && windowVisible && !frozen }

  /// A fixed state for design shots and tests: no call, no timer, no account watch.
  func seed(_ state: ConnectorsState) {
    frozen = true
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
    self.state = state
  }

  // MARK: Page, window and app events

  /// The pane became visible: read now, then every 5 minutes while it stays. An answer of another account is dropped
  /// first, so old names never show while the new call runs.
  func pageDidAppear() {
    pageVisible = true
    watchAccount()
    _ = resetIfAccountChanged()
    updateTimer()
    Task { await refresh() }
  }

  /// The pane left the screen: no timer, no calls, no account watch.
  func pageDidDisappear() {
    pageVisible = false
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
  }

  /// The hosting window was minimised, hidden or covered (false), or is on screen again (true).
  func windowVisibilityChanged(_ visible: Bool) {
    guard visible != windowVisible else { return }
    windowVisible = visible
    updateTimer()
    guard visible, pageVisible else { return }
    _ = resetIfAccountChanged()
    Task { await refresh() }
  }

  /// The app got focus (the person may have changed things in Portal or Connect). Only a visible pane reads.
  func appDidBecomeActive() {
    guard canRead else { return }
    Task { await refresh() }
  }

  /// The 5-minute tick. A background app does not read.
  func visibleTimerFired() {
    guard canRead, isAppActive() else { return }
    Task { await refresh() }
  }

  /// Any change of the account (sign in or out, workspace, profile, issuer, email) while the pane is visible: drop the
  /// answer of the old account at once, then read again.
  func accountDidChange() {
    guard pageVisible, !frozen else { return }
    _ = resetIfAccountChanged()
    Task { await refresh() }
  }

  private func watchAccount() {
    guard subscriptions.isEmpty, !frozen else { return }
    // `objectWillChange` fires before the value changes: look at the account on the next turn.
    TBDAccountCoordinator.shared.objectWillChange.sink { [weak self] _ in
      Task { @MainActor in self?.accountDidChange() }
    }.store(in: &subscriptions)
  }

  private func updateTimer() {
    guard canRead else {
      timer?.invalidate()
      timer = nil
      return
    }
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.visibleTimerFired() }
    }
  }

  /// If the account differs from the account of the answer in `state`, drop the answer: no accounts, no choices, "checking".
  @discardableResult
  private func resetIfAccountChanged() -> Bool {
    guard !frozen else { return false }
    let key = accountNow()
    guard key != answerKey else { return false }
    answerKey = key
    choicesRevision += 1
    state = .initial(signedIn: key.signedIn)
    return true
  }

  // MARK: Refresh

  /// One read: plan, agent connection, accounts, remembered choices. Skipped when the pane or its window is not visible, a
  /// refresh is running, or the store is frozen. Signed out: no helper call.
  func refresh() async {
    guard canRead, !inFlight else { return }
    _ = resetIfAccountChanged()
    let key = accountNow()
    guard key.signedIn else {
      let next = ConnectorsState(gate: .signedOut, loaded: key.checked)
      if state != next { state = next }
      return
    }
    inFlight = true
    refreshCount += 1
    defer { inFlight = false }
    let revision = choicesRevision
    let access = await client.access()
    var connected = false
    var probe: TBDConnectorsProbe = .unanswered
    var found: [TBDConnectorAccount] = []
    var rules: [TBDConnectorChoice]?
    // Paid for, or the plan is not known (unknown never locks: a working grant through the relay is proof). Never for a
    // locked or not-installed Connect.
    if access == .unlocked || access == .unknown {
      connected = await client.agentConnected()
      if connected {
        do {
          let list = try await client.accounts()
          if list.available {
            probe = .available
            found = list.accounts
          } else {
            probe = .unavailable(list.reason ?? TBDConnectors.notConnectedLine)
          }
        } catch {
          probe = .failed(error.localizedDescription)
        }
        rules = try? await client.choices()
      }
    }
    // The pane or its window left, or the account changed, while the calls ran.
    guard canRead else { return }
    guard accountNow() == key else {
      // This answer is old. Read again once this refresh is done.
      Task { @MainActor in await self.refresh() }
      return
    }
    answerKey = key
    let decided = TBDConnectors.decide(access: access, agentConnected: connected, probe: probe)
    var next = ConnectorsState(gate: decided, accounts: decided == .active ? found : [], loaded: true)
    if choicesRevision == revision {
      next.choices = rules ?? []
    } else {
      next.choices = state.choices  // a choice was forgotten while the calls ran: keep the newer list
    }
    // A failed check while the last answer is still good: keep the list, say why it may be old.
    if case .failed(let sentence) = decided, state.gate == .active, state.loaded {
      next.gate = .active
      next.accounts = state.accounts
      next.notice = sentence
    }
    if state != next { state = next }
  }

  // MARK: Forget a choice

  /// "Remove": forgets one remembered choice (a local file; the next call of that tool asks again). Returns false when it failed.
  @discardableResult
  func remove(_ choice: TBDConnectorChoice) async -> Bool {
    guard !frozen else { return false }
    let key = accountNow()
    choicesRevision += 1
    do {
      let left = try await client.revoke(account: choice.account, tool: choice.tool)
      guard accountNow() == key else { return true }
      state.choices = left
      return true
    } catch {
      return false
    }
  }
}
