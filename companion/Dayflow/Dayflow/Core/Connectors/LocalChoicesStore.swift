//
//  LocalChoicesStore.swift
//  TBD
//
//  Settings › Access, "Your choices for TBD's agent on this Mac" (dev.17, C280 C13 local part). The person's remembered
//  "Always allow" / "Never allow" answers for TBD's agent's shell commands, file writes and web requests. A local file in the
//  Chat helper (`local-consent.json`, the same for every workspace), read through `localConsentList` and forgotten with
//  `localConsentRevoke`. A failed read says so and never reads as "no choices". Refresh: when the pane appears and when the app
//  gets focus; never while the pane or its window is not visible, never while a refresh is running.
//

import AppKit
import Combine
import Foundation
import TBDModels

@MainActor
protocol LocalChoicesClient {
  /// The remembered choices. Throws when the helper cannot answer.
  func choices() async throws -> TBDLocalChoices
  /// Forgets one choice (by its key); returns the list that is left.
  func revoke(key: String) async throws -> TBDLocalChoices
}

@MainActor
struct LocalChoicesLiveClient: LocalChoicesClient {
  func choices() async throws -> TBDLocalChoices {
    TBDLocalChoices(helperValue: try await TBDChatRuntime.shared.accountCall("localConsentList"))
  }

  func revoke(key: String) async throws -> TBDLocalChoices {
    TBDLocalChoices(helperValue: try await TBDChatRuntime.shared.accountCall("localConsentRevoke", args: [["key": key]]))
  }
}

struct LocalChoicesState: Equatable {
  var choices: [TBDLocalChoice] = []
  /// Why the list may not be whole: the helper could not be asked, or the file was unreadable (a copy was kept).
  var issue: TBDChoicesIssue?
  /// The first answer arrived.
  var loaded = false
}

@MainActor
final class LocalChoicesStore: ObservableObject {
  static let shared = LocalChoicesStore()

  @Published private(set) var state = LocalChoicesState()
  /// The last "Remove" failed. Cleared by the next remove or a good refresh.
  @Published private(set) var removeFailed = false

  private let client: LocalChoicesClient
  private var inFlight = false
  /// Bumped by a remove: a refresh that started before it must not bring the forgotten choice back.
  private var revision = 0
  private(set) var pageVisible = false
  private(set) var windowVisible = true
  /// Design shots and tests seed a state and never ask the helper.
  private(set) var frozen = false
  /// Refreshes that reached the helper (tests).
  private(set) var refreshCount = 0

  init(client: LocalChoicesClient? = nil) {
    self.client = client ?? LocalChoicesLiveClient()
  }

  var isRefreshing: Bool { inFlight }
  private var canRead: Bool { pageVisible && windowVisible && !frozen }

  /// A fixed state for design shots and tests: no call.
  func seed(_ state: LocalChoicesState, removeFailed: Bool = false) {
    frozen = true
    self.state = state
    self.removeFailed = removeFailed
  }

  func pageDidAppear() {
    pageVisible = true
    Task { await refresh() }
  }

  func pageDidDisappear() {
    pageVisible = false
  }

  func windowVisibilityChanged(_ visible: Bool) {
    guard visible != windowVisible else { return }
    windowVisible = visible
    guard visible, pageVisible else { return }
    Task { await refresh() }
  }

  func appDidBecomeActive() {
    guard canRead else { return }
    Task { await refresh() }
  }

  /// One read. Skipped when the pane or its window is not visible, a refresh is running, or the store is frozen.
  func refresh() async {
    guard canRead, !inFlight else { return }
    inFlight = true
    refreshCount += 1
    defer { inFlight = false }
    let started = revision
    var answer: TBDLocalChoices?
    do { answer = try await client.choices() } catch { answer = nil }
    guard canRead else { return }
    var next = state
    next.loaded = true
    if revision != started {
      // A choice was forgotten while the call ran: the newer list stays.
    } else if let answer {
      next.choices = answer.choices
      next.issue = answer.unreadable ? .unreadable : nil
      removeFailed = false
    } else {
      // The list of the last good answer stays; the sentence says it may be old.
      next.issue = .failed
    }
    if state != next { state = next }
  }

  /// "Remove": forgets one choice (a local file; the next such action asks again). Returns false when it failed.
  @discardableResult
  func remove(_ choice: TBDLocalChoice) async -> Bool {
    guard !frozen else { return false }
    revision += 1
    do {
      let left = try await client.revoke(key: choice.key)
      state = LocalChoicesState(choices: left.choices, issue: left.unreadable ? .unreadable : nil, loaded: true)
      removeFailed = false
      return true
    } catch {
      removeFailed = true
      return false
    }
  }
}
