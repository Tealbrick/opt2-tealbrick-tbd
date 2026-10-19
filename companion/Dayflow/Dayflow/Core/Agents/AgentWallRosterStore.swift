//
//  AgentWallRosterStore.swift
//  TBD
//
//  The roster of the Agents wall (WP-WALL). One read-only helper call, `listAgents`, through the account channel.
//  Refresh: when the page appears, every 60 seconds while it is visible, and when the app gets focus. Never while a call
//  is in flight, never while the page is not visible or its window is minimised or hidden. Signed out: no call at all,
//  TBD's own brick and a notice. An answer belongs to one account (signed in, workspace, profile, issuer, email); when
//  the account differs, the old names are dropped before the new call answers.
//

import AppKit
import Combine
import Foundation

/// What the wall needs from the helper. The live one is `AgentWallLiveRosterClient`; tests use a fake.
@MainActor
protocol AgentWallRosterClient {
  /// The helper's `listAgents` answer, undecoded.
  func listAgents() async throws -> Any
}

@MainActor
struct AgentWallLiveRosterClient: AgentWallRosterClient {
  func listAgents() async throws -> Any { try await TBDChatRuntime.shared.accountCall("listAgents") }
}

/// The account an answer belongs to. A different key means the roster on screen is not this account's roster.
struct AgentWallAccountKey: Equatable {
  var signedIn: Bool
  /// The account has told whether a session exists (`hasCheckedSession`).
  var checked = true
  var workspace = ""
  var profile = ""
  var issuer = ""
  var email = ""
}

extension TBDAccountCoordinator {
  /// The key of the account now (read-only).
  var wallKey: AgentWallAccountKey {
    AgentWallAccountKey(
      signedIn: signedIn, checked: hasCheckedSession, workspace: activeWorkspace, profile: activeProfile,
      issuer: profiles.first { $0.id == activeProfile }?.issuer ?? "", email: email)
  }
}

/// Whether the hosting window shows the wall: not minimised and at least partly visible (not occluded).
enum AgentWallWindowVisibility {
  static func isVisible(occlusion: NSWindow.OcclusionState, miniaturized: Bool) -> Bool {
    !miniaturized && occlusion.contains(.visible)
  }
}

@MainActor
final class AgentWallRosterStore: ObservableObject {
  static let shared = AgentWallRosterStore()
  /// Re-read period while the Agents page is visible.
  static let interval: TimeInterval = 60

  @Published private(set) var state = AgentWallState()
  /// The slot order of the bricks (see `AgentWallSlotBook`). Set before `state`, so a new answer never draws with an old order.
  @Published private(set) var slotOrder: [String] = []

  private let client: AgentWallRosterClient
  private let accountNow: () -> AgentWallAccountKey
  private let isAppActive: () -> Bool
  private let slotDefaults: UserDefaults
  private let now: () -> Date
  private var slotBook: AgentWallSlotBook
  private var timer: Timer?
  private var subscriptions = Set<AnyCancellable>()
  private var inFlight = false
  /// The account of the roster in `state`.
  private var answerKey: AgentWallAccountKey
  /// The page is on screen. The helper is asked only then.
  private(set) var pageVisible = false
  /// The hosting window is on screen (not minimised, not hidden). The helper is asked only then.
  private(set) var windowVisible = true
  /// Design shots and tests seed a state and never ask the helper.
  private(set) var frozen = false
  /// Calls made so far (tests).
  private(set) var callCount = 0

  init(
    client: AgentWallRosterClient? = nil, signedIn: (() -> Bool)? = nil, account: (() -> AgentWallAccountKey)? = nil,
    isAppActive: (() -> Bool)? = nil, slotDefaults: UserDefaults = .standard, now: (() -> Date)? = nil
  ) {
    self.client = client ?? AgentWallLiveRosterClient()
    if let account {
      accountNow = account
    } else if let signedIn {
      accountNow = { AgentWallAccountKey(signedIn: signedIn()) }
    } else {
      accountNow = { TBDAccountCoordinator.shared.wallKey }
    }
    self.isAppActive = isAppActive ?? { NSApplication.shared.isActive }
    self.slotDefaults = slotDefaults
    self.now = now ?? { Date() }
    slotBook = AgentWallSlotBook(defaults: slotDefaults)
    slotOrder = slotBook.order
    let key = accountNow()
    answerKey = key
    state = Self.ownOnlyState(for: key)
  }

  /// TBD alone for this account, nothing loaded yet. Signed out before the session check: no sign-in notice.
  private static func ownOnlyState(for key: AgentWallAccountKey) -> AgentWallState {
    AgentWallState(roster: .ownOnly, signedIn: key.signedIn, loaded: false, sessionChecked: key.checked)
  }

  /// The 60-second timer runs (only while the page and its window are visible).
  var isPolling: Bool { timer != nil }
  var isRefreshing: Bool { inFlight }
  private var canRead: Bool { pageVisible && windowVisible && !frozen }

  /// A fixed state for design shots: no call, no timer, no account watch, nothing written to UserDefaults.
  func seed(_ roster: AgentWallRoster, signedIn: Bool) {
    frozen = true
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
    var book = AgentWallSlotBook()
    book.update(with: roster.agents, now: now())
    slotOrder = book.order
    state = AgentWallState(roster: roster, signedIn: signedIn, loaded: true)
  }

  // MARK: Page, window and app events

  /// The Agents page became visible: read now, then every 60 seconds while it stays. An answer of another account is
  /// dropped first, so old names never show while the new call runs.
  func pageDidAppear() {
    pageVisible = true
    watchAccount()
    _ = resetIfAccountChanged()
    updateTimer()
    Task { await refresh() }
  }

  /// The page left the screen: no timer, no calls, no account watch.
  func pageDidDisappear() {
    pageVisible = false
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
  }

  /// The hosting window was minimised, hidden or covered (false), or is on screen again (true). No timer, no calls while
  /// it is not visible; when it is back, the roster is read again.
  func windowVisibilityChanged(_ visible: Bool) {
    guard visible != windowVisible else { return }
    windowVisible = visible
    updateTimer()
    guard visible, pageVisible else { return }
    _ = resetIfAccountChanged()
    Task { await refresh() }
  }

  /// The app got focus. Only a visible page reads.
  func appDidBecomeActive() {
    guard canRead else { return }
    Task { await refresh() }
  }

  /// The 60-second tick. A background app does not read.
  func visibleTimerFired() {
    guard canRead, isAppActive() else { return }
    Task { await refresh() }
  }

  /// Any change of the account (sign in or out, workspace, profile, issuer, email, session check) while the page is
  /// visible: drop an answer of the old account at once, then read again.
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

  /// If the account differs from the account of the roster in `state`, fall back to TBD alone with `loaded: false`.
  @discardableResult
  private func resetIfAccountChanged() -> Bool {
    guard !frozen else { return false }
    let key = accountNow()
    guard key != answerKey else { return false }
    answerKey = key
    state = Self.ownOnlyState(for: key)
    return true
  }

  // MARK: Refresh

  /// One read. Skipped when the page or its window is not visible, a call is in flight, or the store is frozen.
  func refresh() async {
    guard canRead, !inFlight else { return }
    _ = resetIfAccountChanged()
    let key = accountNow()
    guard key.signedIn else {
      // No helper call without an account: TBD's own brick and the sign-in notice (not before the session check).
      let next = AgentWallState(roster: .ownOnly, signedIn: false, loaded: key.checked, sessionChecked: key.checked)
      if state != next { state = next }
      return
    }
    inFlight = true
    callCount += 1
    defer { inFlight = false }
    let answer = try? await client.listAgents()
    // The page or its window left, or the account changed, while the call ran.
    guard canRead else { return }
    guard accountNow() == key else {
      // The account changed during the call: this answer is old. Read again once this call is done.
      Task { @MainActor in await self.refresh() }
      return
    }
    answerKey = key
    if let answer {
      let roster = AgentWallRoster.decode(answer)
      slotBook.update(with: roster.agents, now: now())
      slotBook.save(to: slotDefaults)
      slotOrder = slotBook.order
      state = AgentWallState(roster: roster, signedIn: true, loaded: true)
    } else {
      // The helper did not answer: keep the last roster of this account (TBD alone on the first load) and say so.
      var roster = state.signedIn ? state.roster : .ownOnly
      roster.notice = "The agents of your workspace could not be loaded. TBD tries again in a minute."
      state = AgentWallState(roster: roster, signedIn: true, loaded: true)
    }
  }
}
