//
//  FlowNativeState.swift
//  TBD
//
//  Flow session state as the desktop overlay and the observer need it. Port of v1 FlowNativeState without the webview
//  bridge payloads: `FlowPlanner` derives the snapshot from the local list (`TBDFlowSession`) and applies it to the
//  mirror. Timestamps are unix seconds so the overlay can count down locally.
//

import Foundation
import TBDModels

enum FlowAlertStyle: String, Codable, CaseIterable {
  case quiet
  case friendly
  case feisty
}

enum FlowPhase: String, Codable {
  case idle
  case active
  case onBreak = "break"
  case ended
}

/// Snapshot the planner pushes whenever session state changes.
struct FlowNativeSnapshot: Codable, Equatable {
  var phase: FlowPhase = .idle
  var alertStyle: FlowAlertStyle = .friendly
  /// nil when idle.
  var sessionEndsAt: Int?
  var breakEndsAt: Int?
  /// When the active session began (unix seconds); nil when idle.
  var sessionStartedAt: Int?
  /// The open tasks the session is about, with their ids (the observer ticks them off).
  var goals: [TBDFlowGoal] = []

  static let idle = FlowNativeSnapshot()

  /// The goal titles (for the nudge preview and the debug panel).
  var goalTitles: [String] { goals.map(\.title) }

  static let defaultsKey = "flowNativeSnapshot"

  static func loadPersisted(defaults: UserDefaults = .standard) -> FlowNativeSnapshot {
    guard let data = defaults.data(forKey: defaultsKey),
      let snapshot = try? JSONDecoder().decode(FlowNativeSnapshot.self, from: data)
    else { return .idle }
    return snapshot
  }

  func persist(defaults: UserDefaults = .standard) {
    guard let data = try? JSONEncoder().encode(self) else { return }
    defaults.set(data, forKey: Self.defaultsKey)
  }
}

/// What the overlay panel is currently showing.
enum FlowOverlayPresentation: Equatable {
  case hidden
  /// Short auto-dismissing speech bubble ("Your flow session starts now!").
  case toast(message: String)
  /// Distraction nudge with quick-reply pills. `escalated` marks a repeat nudge in the same incident: the creature
  /// loses its temper (fire clips) instead of waving. The message is written by the detection agent (or a stock line
  /// for the ⌘⇧D simulation).
  case nudge(message: String, escalated: Bool)
  /// Break in progress: tub + countdown driven by `breakEndsAt`.
  case onBreak
  /// Timed session hit its natural end.
  case sessionEnded
}

/// Where the nudge creature comes from. `side` peeks in at the bottom-right corner; `top` drops down from the top edge,
/// lands and listens; `peek` hangs half-body from the top edge. Chosen from the app menu or the nudge preview; toasts
/// and breaks always use the side layout.
enum FlowNudgeVariant: String, CaseIterable {
  case side
  case top
  case peek

  static let defaultsKey = "flowNudgeVariant"

  static var current: FlowNudgeVariant {
    get {
      UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .side
    }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
  }

  var next: FlowNudgeVariant {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + 1) % all.count]
  }

  var title: String {
    switch self {
    case .side: return "Side"
    case .top: return "Drop from top"
    case .peek: return "Peek from top"
    }
  }

  /// Panel hugs the top edge of the screen for the from-above variants.
  var anchorsToTop: Bool { self != .side }
}

/// Which pill the user tapped on the last nudge; picks the matching exit clip.
enum FlowNudgeReply {
  case backToWork
  case snooze
  case correct
}
