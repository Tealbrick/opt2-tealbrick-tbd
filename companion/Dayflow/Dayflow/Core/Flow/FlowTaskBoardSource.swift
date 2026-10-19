//
//  FlowTaskBoardSource.swift
//  TBD
//
//  Flow's Task Board source (F4, C282, DESIGN-FLOW 2.3). Decides which list Flow shows: Task Board when the plan says
//  Task Board is licensed for the workspace, TBD's agent is connected and the helper's list check answered
//  "available"; otherwise the list on this Mac. Reads the owner's open issues, and marks one done ONLY when the
//  person taps. Every call goes through the Chat helper as TBD's own agent (never the person's token). Flow never
//  creates a Task Board issue.
//

import Combine
import Foundation
import TBDModels

/// What Flow needs from the helper. The live one is `FlowLiveTaskBoardClient`; tests use a fake.
@MainActor
protocol FlowTaskBoardClient {
  /// The plan's answer for Task Board in the active workspace; `.unknown` when it cannot be read.
  func access() async -> TBDAppAccess
  func agentConnected() async -> Bool
  func list() async throws -> TBDFlowTaskBoardList
  /// Marks the issue done; `onStatus` gets "Waiting for owner approval" on a hold. Returns the issue's new status.
  func complete(issue: String, result: String, onStatus: @escaping @MainActor (String) -> Void) async throws -> String
}

/// The helper over the account channel.
@MainActor
struct FlowLiveTaskBoardClient: FlowTaskBoardClient {
  func access() async -> TBDAppAccess {
    // Nobody signed in: nothing is paid for, and no helper call is made.
    guard TBDAccountCoordinator.shared.signedIn else { return .locked }
    let value = try? await TBDChatRuntime.shared.accountCall("entitlements")
    return TBDEntitlements(helperValue: value).access(.kanban)
  }

  func agentConnected() async -> Bool {
    guard TBDAccountCoordinator.shared.signedIn else { return false }
    let value = try? await TBDChatRuntime.shared.accountCall("agentConnection") as? [String: Any]
    return value?["connected"] as? Bool ?? false
  }

  func list() async throws -> TBDFlowTaskBoardList {
    let value = try await TBDChatRuntime.shared.accountCall("flowTaskBoardList")
    guard let list = TBDFlowTaskBoardList(helperValue: value) else {
      throw NSError(domain: "TBD.Flow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Task Board gave an answer TBD does not understand. Try again."])
    }
    return list
  }

  func complete(issue: String, result: String, onStatus: @escaping @MainActor (String) -> Void) async throws -> String {
    try await TBDChatRuntime.shared.flowTaskBoardComplete(issue: issue, result: result, onStatus: onStatus)
  }
}

@MainActor
final class FlowTaskBoardSource: ObservableObject {
  static let shared = FlowTaskBoardSource()
  /// Re-check period while the Flow page is visible.
  static let interval: TimeInterval = 10 * 60
  /// A page open right after a check does not ask the helper again.
  static let minGap: TimeInterval = 15

  @Published private(set) var mode: TBDFlowSourceMode = .local(.checking)
  /// The owner's open issues from the last good check (in progress first, then todo). Empty unless `mode == .taskBoard`.
  @Published private(set) var issues: [TBDFlowTaskBoardIssue] = []

  private let client: FlowTaskBoardClient
  private let now: () -> Date
  private var timer: Timer?
  private var subscriptions = Set<AnyCancellable>()
  private var checking = false
  private var lastCheck: Date?
  /// The Flow page is on screen. Task Board is asked only then.
  private(set) var pageVisible = false
  /// The last list call came back "held" (the owner has not approved sharing the list yet). Only the person opening the
  /// page, or an account change, asks again; the timer does not.
  private var listHeld = false
  /// Design shots seed a state and never ask the helper.
  private var frozen = false

  init(client: FlowTaskBoardClient? = nil, now: @escaping () -> Date = { Date() }) {
    self.client = client ?? FlowLiveTaskBoardClient()
    self.now = now
  }

  var isTaskBoard: Bool { mode.isTaskBoard }
  /// The line above the plan; nil when Task Board is the source.
  var notice: String? { TBDFlowSource.notice(mode) }
  /// The 10-minute timer runs (only while the page is visible).
  var isPolling: Bool { timer != nil }

  // MARK: Checks

  /// Watches the account (the signed-in state and the workspace). It asks the helper only while the Flow page is visible
  /// (no background polling). The AppDelegate calls it once; never in the XCTest host.
  func start() {
    guard subscriptions.isEmpty, !frozen else { return }
    let account = TBDAccountCoordinator.shared
    account.$signedIn.dropFirst().sink { [weak self] _ in self?.accountChanged() }.store(in: &subscriptions)
    account.$activeWorkspace.dropFirst().removeDuplicates().sink { [weak self] _ in self?.accountChanged() }
      .store(in: &subscriptions)
  }

  func stop() {
    pageDidDisappear()
    subscriptions.removeAll()
  }

  /// The Flow page became visible: check now (skipped when a check ran a moment ago), then every 10 minutes while it stays.
  func pageDidAppear() {
    pageVisible = true
    if timer == nil, !frozen {
      timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.visibleTimerFired() }
      }
    }
    Task { await recheck() }
  }

  /// The Flow page left the screen: no more checks.
  func pageDidDisappear() {
    pageVisible = false
    timer?.invalidate()
    timer = nil
  }

  /// The signed-in state or the workspace changed: ask again, but only when the page is visible.
  func accountChanged() {
    guard pageVisible else { return }
    listHeld = false
    Task { await recheck(force: true) }
  }

  /// The 10-minute tick while the page is visible. A held list is not asked again by the timer.
  func visibleTimerFired() {
    guard pageVisible, !listHeld else { return }
    Task { await recheck(force: true) }
  }

  /// One check: plan → agent connection → list. The Flow page calls it when it opens (`force` false: skipped when a
  /// check ran a moment ago). A failed check falls back to the list on this Mac and says why. Never starts while another
  /// check is pending.
  func recheck(force: Bool = false) async {
    guard !frozen, !checking else { return }
    if !force, let last = lastCheck, now().timeIntervalSince(last) < Self.minGap { return }
    checking = true
    defer { checking = false }
    let access = await client.access()
    var connected = false
    var probe: TBDFlowTaskBoardProbe = .unanswered
    var found: [TBDFlowTaskBoardIssue] = []
    var held = false
    // The agent and the list are asked when the plan says Task Board is paid for, or when the plan is not known yet
    // (unknown never locks: a working grant through the relay is proof). Never for a locked or not-installed app.
    if access == .unlocked || access == .unknown {
      connected = await client.agentConnected()
      if connected {
        do {
          let list = try await client.list()
          if list.available {
            probe = .available
            found = list.issues
          } else {
            probe = .unavailable(list.reason ?? TBDFlowSource.notConnectedNotice)
          }
        } catch {
          probe = .failed(error.localizedDescription)
          held = error.localizedDescription == TBDFlowSource.listWaitingNotice
        }
      }
    }
    listHeld = held
    let decided = TBDFlowSource.decide(access: access, agentConnected: connected, probe: probe)
    lastCheck = now()
    if mode != decided { mode = decided }
    let next = decided.isTaskBoard ? found : []
    if issues != next { issues = next }
  }

  // MARK: Writes (only on the person's tap)

  /// "Mark done on Task Board". The caller has the person's tap; a hold reports through `onStatus`.
  func complete(issue: String, result: String, onStatus: @escaping @MainActor (String) -> Void) async throws -> String {
    let status = try await client.complete(issue: issue, result: result, onStatus: onStatus)
    // Only "done" counts. Any other status is an error on the row: the issue is still open on Task Board.
    guard status == "done" else {
      throw NSError(
        domain: "TBD.Flow", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Task Board did not mark it done. Check the issue on Task Board."])
    }
    // The issue is no longer open: take it out of the sheet's list without waiting for the next check.
    issues.removeAll { $0.id == issue }
    return status
  }

  // MARK: Design shots and tests

  /// Sets a state without asking the helper (design shots). Later checks do nothing.
  func seed(mode: TBDFlowSourceMode, issues: [TBDFlowTaskBoardIssue]) {
    frozen = true
    self.mode = mode
    self.issues = issues
  }
}
