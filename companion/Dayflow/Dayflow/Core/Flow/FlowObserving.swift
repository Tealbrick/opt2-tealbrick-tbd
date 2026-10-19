//
//  FlowObserving.swift
//  TBD
//
//  The seam between the session mirror and the screen observer. Slice F2 ships only the protocol and a no-op
//  implementation; slice F3 plugs the real observer (`FlowDistractionAgent`) into `FlowSessionMirror.observer`.
//

import Foundation

@MainActor
protocol FlowObserving: AnyObject {
  /// One line for the Flow page and the debug panel ("Observer: off" ...).
  var status: String { get }
  /// A session began (or, with `rebrief`, the app relaunched in the middle of one and the observer starts a fresh
  /// conversation with the same facts).
  func start(with snapshot: FlowNativeSnapshot, rebrief: Bool)
  /// A break began: stop looking at the screen.
  func pause()
  /// The break ended.
  func resume()
  /// The session ended or went idle.
  func stop()
  /// Goals changed in an active session (a task was added or ticked off).
  func goalsChanged(to snapshot: FlowNativeSnapshot)
  /// A person's reply to a nudge, as a note for the model. `markRefocused` tells the observer the person is back on task.
  func noteUserEvent(_ note: String, markRefocused: Bool)
}

extension FlowObserving {
  func noteUserEvent(_ note: String) { noteUserEvent(note, markRefocused: false) }
}

/// The default observer until F3: it watches nothing.
@MainActor
final class FlowNoObserver: FlowObserving {
  var status: String { "Observer: not set up yet" }
  func start(with snapshot: FlowNativeSnapshot, rebrief: Bool) {}
  func pause() {}
  func resume() {}
  func stop() {}
  func goalsChanged(to snapshot: FlowNativeSnapshot) {}
  func noteUserEvent(_ note: String, markRefocused: Bool) {}
}
