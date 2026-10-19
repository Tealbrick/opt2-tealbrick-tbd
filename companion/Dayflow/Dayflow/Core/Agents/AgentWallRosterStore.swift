//
//  AgentWallRosterStore.swift
//  TBD
//
//  The roster of the Agents wall (WP-WALL). One read-only helper call, `listAgents`, through the account channel.
//  Refresh: when the page appears, every 60 seconds while it is visible, and when the app gets focus. Never while a call
//  is in flight, never while the page is not visible. Signed out: no call at all, TBD's own brick and a notice.
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

@MainActor
final class AgentWallRosterStore: ObservableObject {
  static let shared = AgentWallRosterStore()
  /// Re-read period while the Agents page is visible.
  static let interval: TimeInterval = 60

  @Published private(set) var state = AgentWallState()

  private let client: AgentWallRosterClient
  private let signedInNow: () -> Bool
  private let isAppActive: () -> Bool
  private var timer: Timer?
  private var subscriptions = Set<AnyCancellable>()
  private var inFlight = false
  /// The page is on screen. The helper is asked only then.
  private(set) var pageVisible = false
  /// Design shots and tests seed a state and never ask the helper.
  private(set) var frozen = false
  /// Calls made so far (tests).
  private(set) var callCount = 0

  init(
    client: AgentWallRosterClient? = nil, signedIn: (() -> Bool)? = nil, isAppActive: (() -> Bool)? = nil
  ) {
    self.client = client ?? AgentWallLiveRosterClient()
    let signedInNow = signedIn ?? { TBDAccountCoordinator.shared.signedIn }
    self.signedInNow = signedInNow
    self.isAppActive = isAppActive ?? { NSApplication.shared.isActive }
    state.signedIn = signedInNow()
  }

  /// The 60-second timer runs (only while the page is visible).
  var isPolling: Bool { timer != nil }
  var isRefreshing: Bool { inFlight }

  /// A fixed state for design shots: no call, no timer, no account watch.
  func seed(_ roster: AgentWallRoster, signedIn: Bool) {
    frozen = true
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
    state = AgentWallState(roster: roster, signedIn: signedIn, loaded: true)
  }

  // MARK: Page and app events

  /// The Agents page became visible: read now, then every 60 seconds while it stays.
  func pageDidAppear() {
    pageVisible = true
    watchAccount()
    if timer == nil, !frozen {
      timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.visibleTimerFired() }
      }
    }
    Task { await refresh() }
  }

  /// The page left the screen: no timer, no calls, no account watch.
  func pageDidDisappear() {
    pageVisible = false
    timer?.invalidate()
    timer = nil
    subscriptions.removeAll()
  }

  /// The app got focus. Only a visible page reads.
  func appDidBecomeActive() {
    guard pageVisible else { return }
    Task { await refresh() }
  }

  /// The 60-second tick. A background app does not read.
  func visibleTimerFired() {
    guard pageVisible, isAppActive() else { return }
    Task { await refresh() }
  }

  /// Sign in or out while the page is visible: read again (or fall back to TBD alone).
  private func watchAccount() {
    guard subscriptions.isEmpty, !frozen else { return }
    TBDAccountCoordinator.shared.$signedIn.dropFirst().removeDuplicates().sink { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    }.store(in: &subscriptions)
  }

  // MARK: Refresh

  /// One read. Skipped when the page is not visible, a call is in flight, or the store is frozen.
  func refresh() async {
    guard pageVisible, !frozen, !inFlight else { return }
    let signedIn = signedInNow()
    guard signedIn else {
      // No helper call without an account: TBD's own brick and the sign-in notice.
      let next = AgentWallState(roster: .ownOnly, signedIn: false, loaded: true)
      if state != next { state = next }
      return
    }
    inFlight = true
    callCount += 1
    defer { inFlight = false }
    let answer = try? await client.listAgents()
    // The page left, or the account changed, while the call ran.
    guard pageVisible, !frozen else { return }
    guard signedInNow() == signedIn else {
      // The account changed during the call: this answer is old. Read again once this call is done.
      Task { @MainActor in await self.refresh() }
      return
    }
    if let answer {
      state = AgentWallState(roster: .decode(answer), signedIn: true, loaded: true)
    } else {
      // The helper did not answer: keep the last roster and say so.
      var roster = state.signedIn ? state.roster : .ownOnly
      roster.notice = "The agents of your workspace could not be loaded. TBD tries again in a minute."
      state = AgentWallState(roster: roster, signedIn: true, loaded: true)
    }
  }
}
