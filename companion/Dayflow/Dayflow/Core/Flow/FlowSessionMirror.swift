//
//  FlowSessionMirror.swift
//  TBD
//
//  Holds the native mirror of Flow session state and decides what the desktop overlay shows. `FlowPlanner` pushes the
//  snapshot (derived from the local list); the observer (`FlowObserving`, slice F3) reports what it sees. Port of v1
//  without the webview bridge, the Codex re-brief path and analytics.
//

import AppKit
import Foundation
import TBDModels

@MainActor
final class FlowSessionMirror: ObservableObject {
  static let shared = FlowSessionMirror()

  @Published private(set) var snapshot: FlowNativeSnapshot
  @Published private(set) var overlay: FlowOverlayPresentation = .hidden {
    didSet {
      // The variant is fixed per appearance: picked when a nudge brings the creature on screen, kept through the
      // follow-up toast, and reset to the side layout for anything that starts from hidden or needs the tub (bath
      // clips are authored for the bottom-right corner).
      if case .nudge = overlay {
        if oldValue == .hidden {
          overlayVariant = FlowNudgeVariant(rawValue: defaults.string(forKey: FlowNudgeVariant.defaultsKey) ?? "") ?? .side
          lastNudgeReply = nil
        }
      } else if overlay == .onBreak || oldValue == .hidden {
        overlayVariant = .side
      }
    }
  }
  /// Layout/clip family for what's on screen right now (see FlowNudgeVariant).
  @Published private(set) var overlayVariant: FlowNudgeVariant = .side
  private(set) var lastNudgeReply: FlowNudgeReply?
  /// True between a (simulated) distraction firing and the user responding.
  @Published private(set) var isDistracted = false

  /// The screen observer. `FlowNoObserver` until slice F3 plugs the real one in with `setObserver`.
  private(set) var observer: FlowObserving
  /// The planner ticks goals off when the observer saw them finished (`FlowPlanner.start` sets this).
  var onGoalsCompleted: (([TBDFlowGoal]) -> Void)?
  /// Which of the goals the observer finished were really checked off (asked after `onGoalsCompleted`); the "Checked off"
  /// toast names only those. nil = all of them. A Task Board task is not checked off by the observer (F4).
  var goalsToAnnounce: (([TBDFlowGoal]) -> [TBDFlowGoal])?

  private let defaults: UserDefaults
  private let settings: FlowAgentSettings
  private let timeline: FlowSessionTimeline
  private let now: () -> Date

  private var deadlineTimer: Timer?
  private var toastTimer: Timer?
  /// The tub only stays for its intro clip, then the creature climbs out and the overlay clears so the break doesn't
  /// sit on the screen.
  private var breakOverlayTimer: Timer?
  private var snoozeUntil: Date?
  /// Nudges shown for the current distraction incident; the second one in a row escalates the creature to the fire
  /// animation.
  private var nudgeStreak = 0

  init(
    defaults: UserDefaults = .standard, settings: FlowAgentSettings? = nil,
    timeline: FlowSessionTimeline? = nil, observer: FlowObserving? = nil,
    now: @escaping () -> Date = { Date() }
  ) {
    self.defaults = defaults
    self.settings = settings ?? (defaults === UserDefaults.standard ? .shared : FlowAgentSettings(defaults: defaults))
    self.timeline = timeline ?? .shared
    self.observer = observer ?? FlowNoObserver()
    self.now = now
    // Survive a relaunch mid-session: restore the last snapshot, but drop states that no longer make sense (an
    // expired session).
    var restored = FlowNativeSnapshot.loadPersisted(defaults: defaults)
    if restored.phase != .idle, let endsAt = restored.sessionEndsAt, endsAt <= Int(now().timeIntervalSince1970) {
      restored = .idle
    }
    snapshot = restored
    armDeadlineTimer()
    if restored.phase == .active {
      // Relaunched mid-session: start a fresh observation with the same session facts.
      self.observer.start(with: restored, rebrief: true)
    }
  }

  /// Slice F3: plug in the real observer. A session already running is handed over (as a relaunch).
  func setObserver(_ newObserver: FlowObserving) {
    observer.stop()
    observer = newObserver
    if snapshot.phase == .active { newObserver.start(with: snapshot, rebrief: true) }
  }

  // MARK: - Updates from the planner

  func apply(_ newSnapshot: FlowNativeSnapshot) {
    let previous = snapshot
    snapshot = newSnapshot
    newSnapshot.persist(defaults: defaults)

    switch (previous.phase, newSnapshot.phase) {
    case (.idle, .active), (.ended, .active):
      isDistracted = false
      snoozeUntil = nil
      nudgeStreak = 0
      showToast(String(localized: "Your flow session starts now!"))
      observer.start(with: newSnapshot, rebrief: false)
    case (_, .onBreak):
      showBreak()
      observer.pause()
    case (.onBreak, .active):
      breakOverlayTimer?.invalidate()
      showToast(String(localized: "Break's over. Back to it!"))
      observer.resume()
      observer.goalsChanged(to: newSnapshot)
    case (.active, .active):
      // Tasks added or checked off mid-session.
      observer.goalsChanged(to: newSnapshot)
    case (_, .idle), (_, .ended):
      isDistracted = false
      snoozeUntil = nil
      timeline.finish(at: now())
      observer.stop()
      if case (_, .idle) = (previous.phase, newSnapshot.phase) {
        overlay = .hidden
      }
    default:
      break
    }

    armDeadlineTimer()
  }

  // MARK: - Distraction simulation (⌘⇧D fallback for testing)

  /// Nudge preview: bring the creature in with the given layout, session or not.
  func debugNudge(variant: FlowNudgeVariant, escalated: Bool = false) {
    defaults.set(variant.rawValue, forKey: FlowNudgeVariant.defaultsKey)
    settings.nudgeVariant = variant
    if overlay != .hidden {
      // The variant is fixed per appearance; clear first so the new layout (and its entrance clip) applies.
      overlay = .hidden
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.debugNudge(variant: variant, escalated: escalated)
      }
      return
    }
    snoozeUntil = nil
    overlay = .nudge(
      message: String(localized: "Psst... I think you're getting distracted!"),
      escalated: escalated)
  }

  /// Nudge preview: show the break tub with its normal auto-dismiss.
  func debugBreak() { showBreak() }

  /// A toast with arbitrary text (reminders, finished timers, the nudge preview).
  func toast(_ message: String) { showToast(message) }

  /// Nudge preview: a toast with arbitrary text.
  func debugToast(_ message: String) { showToast(message) }

  /// Nudge preview: dismiss whatever is on screen (plays the exit clip).
  func debugHideOverlay() { overlay = .hidden }

  /// Fires the distraction nudge as if the observer had flagged the user. Quiet mode records nothing visible.
  func simulateDistraction() {
    guard snapshot.phase == .active else { return }
    isDistracted = true
    guard snapshot.alertStyle != .quiet else { return }
    snoozeUntil = nil
    nudgeStreak += 1
    overlay = .nudge(
      message: String(localized: "Psst... I think you're getting distracted!"),
      escalated: nudgeStreak >= 2)
    armDeadlineTimer()
  }

  // MARK: - Observer callbacks

  /// The observer's on-task/off-task read flipped.
  func agentReportedFocusChange(isDistracted distracted: Bool) {
    guard snapshot.phase == .active else { return }
    isDistracted = distracted
    if !distracted { nudgeStreak = 0 }
    if !distracted, case .nudge = overlay {
      overlay = .hidden
    }
  }

  /// Show a nudge written by the observer. Quiet mode and an active snooze both suppress it.
  func agentNudge(message: String) {
    guard snapshot.phase == .active, snapshot.alertStyle != .quiet else { return }
    if let snoozeUntil, snoozeUntil > now() { return }
    nudgeStreak += 1
    overlay = .nudge(message: message, escalated: nudgeStreak >= 2)
  }

  /// The observer saw goals get finished on screen: the planner checks them off, and the creature celebrates unless
  /// it's quiet mode.
  func agentCompletedGoals(_ goals: [TBDFlowGoal]) {
    guard snapshot.phase == .active, !goals.isEmpty else { return }
    onGoalsCompleted?(goals)
    let goals = goalsToAnnounce?(goals) ?? goals
    guard !goals.isEmpty else { return }
    guard snapshot.alertStyle != .quiet else { return }
    if case .nudge = overlay { return }
    let title = goals[0].title
    let message =
      goals.count == 1
      ? String(localized: "Checked off: \(title)")
      : String(localized: "Checked off \(goals.count) tasks, including \(title)")
    showToast(message, seconds: settings.praiseSeconds)
  }

  /// Short encouragement from the observer, shown as an auto-dismissing toast.
  func agentPraise(message: String) {
    guard snapshot.phase == .active, snapshot.alertStyle != .quiet else { return }
    if case .nudge = overlay { return }
    showToast(message, seconds: settings.praiseSeconds)
  }

  // MARK: - Overlay pill actions

  func respondBackToWork() {
    lastNudgeReply = .backToWork
    isDistracted = false
    snoozeUntil = nil
    nudgeStreak = 0
    observer.noteUserEvent("The user tapped \"I'll get back to work\" on your nudge.", markRefocused: true)
    showToast(String(localized: "Nice! Keep at it"))
  }

  func snooze(minutes: Int) {
    lastNudgeReply = .snooze
    observer.userSnoozed()
    snoozeUntil = now().addingTimeInterval(TimeInterval(minutes * 60))
    observer.noteUserEvent(
      "The user snoozed your nudge for \(minutes) minutes. Do not nudge again until the snooze is over unless they switch to something new.",
      markRefocused: false)
    overlay = .hidden
    armDeadlineTimer()
  }

  /// "Correct Flow's mistake": the observer misread the screen. Close the distraction and tell the observer so it
  /// recalibrates.
  func correctMistake() {
    lastNudgeReply = .correct
    isDistracted = false
    snoozeUntil = nil
    nudgeStreak = 0
    observer.noteUserEvent(
      "The user says your nudge was a mistake — they were on task. Trust them, and be more lenient about screens like the one that triggered it.",
      markRefocused: true)
    overlay = .hidden
  }

  func dismissOverlay() {
    overlay = .hidden
  }

  /// "Start a new session" from the session-ended bubble: bring up the app on the Flow page.
  func openFlowTab() {
    overlay = .hidden
    MainWindowController.shared.showMainWindow()
    NSApp.activate(ignoringOtherApps: true)
    NotificationCenter.default.post(name: .navigateToFlow, object: nil)
  }

  // MARK: - Deadlines

  /// Re-arms a single timer for the nearest upcoming deadline: session end, break end, or snooze expiry.
  private func armDeadlineTimer() {
    deadlineTimer?.invalidate()
    deadlineTimer = nil

    var deadlines: [Date] = []
    let current = now()
    if snapshot.phase == .active, let endsAt = snapshot.sessionEndsAt {
      deadlines.append(Date(timeIntervalSince1970: TimeInterval(endsAt)))
    }
    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt {
      deadlines.append(Date(timeIntervalSince1970: TimeInterval(endsAt)))
    }
    if let snoozeUntil {
      deadlines.append(snoozeUntil)
    }
    guard let nearest = deadlines.min() else { return }

    let interval = max(0.5, nearest.timeIntervalSince(current))
    deadlineTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleDeadline()
      }
    }
  }

  /// Runs whatever deadline has passed. The timer calls it; tests call it after moving their clock.
  func handleDeadline() {
    let current = now()
    let seconds = Int(current.timeIntervalSince1970)

    if let snoozeDeadline = snoozeUntil, snoozeDeadline <= current {
      snoozeUntil = nil
      // Still marked distracted after the snooze ran out → nudge again.
      if isDistracted, snapshot.phase == .active, snapshot.alertStyle != .quiet {
        nudgeStreak += 1
        overlay = .nudge(
          message: String(localized: "Snooze is up — ready to get back to it?"),
          escalated: nudgeStreak >= 2)
      }
    }

    if snapshot.phase == .active, let endsAt = snapshot.sessionEndsAt, endsAt <= seconds {
      snapshot.phase = .ended
      snapshot.persist(defaults: defaults)
      overlay = .sessionEnded
      timeline.finish(at: current)
      observer.stop()
    }

    if snapshot.phase == .onBreak, let endsAt = snapshot.breakEndsAt, endsAt <= seconds {
      snapshot.phase = .active
      snapshot.breakEndsAt = nil
      snapshot.persist(defaults: defaults)
      breakOverlayTimer?.invalidate()
      showToast(String(localized: "Break's over. Back to it!"))
    }

    armDeadlineTimer()
  }

  // MARK: - Toasts

  private func showToast(_ message: String, seconds: TimeInterval? = nil) {
    let seconds = seconds ?? settings.toastSeconds
    overlay = .toast(message: message)
    toastTimer?.invalidate()
    toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if case .toast = self.overlay {
          self.overlay = .hidden
        }
      }
    }
  }

  // MARK: - Break

  /// Brings the tub out for the bath intro clip, then hides the overlay again (the controller plays the climb-out clip
  /// on the way).
  private func showBreak() {
    toastTimer?.invalidate()
    overlay = .onBreak
    breakOverlayTimer?.invalidate()
    breakOverlayTimer = Timer.scheduledTimer(
      withTimeInterval: settings.breakOverlaySeconds, repeats: false
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        if self.overlay == .onBreak {
          self.overlay = .hidden
        }
      }
    }
  }
}
