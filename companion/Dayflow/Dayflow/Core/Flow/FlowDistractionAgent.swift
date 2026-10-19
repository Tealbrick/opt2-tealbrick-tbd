//
//  FlowDistractionAgent.swift
//  TBD
//
//  The Flow observer (v1 FlowDistractionAgent) on TBD's own model routes. Each session gets one briefing: the goals, the
//  session length and the alert style. Then, every ~15 seconds, the observer looks at the screen, asks the model and gets
//  a strict one-object JSON verdict. Nudges and praise drive the desktop overlay; on-task/off-task flips drive the session
//  timeline. The model is the TBD "flow" route (`TBDFlowObserverSetup`): text only on this Mac by default (Apple Vision
//  reads the screen, a local model in Ollama judges the text), a local vision model, or a cloud model the person chose.
//  Off until the person turns it on. Port of v1 without the Codex CLI, the Neuu endpoint and analytics.
//
//  Each check is one stateless HTTP call: the briefing goes in the system message with the last replies as context.
//

import AppKit
import Combine
import Foundation
import TBDModels

/// What the observer counted today (the Today card on Flow › Observer). Only numbers: no text from the screen.
struct FlowObserverCounters: Codable, Equatable {
  var day: String
  var checks = 0
  var nudges = 0
  var snoozes = 0
  var offPlanChecks = 0

  static let defaultsKey = "flowObserverCounters"

  static func load(_ defaults: UserDefaults, today: String) -> FlowObserverCounters {
    guard let data = defaults.data(forKey: defaultsKey),
      let stored = try? JSONDecoder().decode(FlowObserverCounters.self, from: data), stored.day == today
    else { return FlowObserverCounters(day: today) }
    return stored
  }

  func save(_ defaults: UserDefaults) {
    if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
  }

  /// "312 checks · 3 nudges · 1 snooze".
  var summary: String {
    func count(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
    return [count(checks, "check"), count(nudges, "nudge"), count(snoozes, "snooze")].joined(separator: " · ")
  }
}

@MainActor
final class FlowDistractionAgent: ObservableObject, FlowObserving {
  static let shared = FlowDistractionAgent()

  /// One line of the debug transcript: what the model said on a turn.
  struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
  }

  /// Model replies (and turn failures) for the debug log.
  @Published private(set) var transcript: [TranscriptEntry] = []
  /// One line for the Flow header and the debug panel.
  @Published private(set) var statusLine = "Observer: off"
  @Published private(set) var lastTickAt: Date?
  @Published private(set) var lastTickSeconds: Double?
  /// The last verdict: true = off plan.
  @Published private(set) var lastOffTask: Bool?
  /// The last thing that went wrong, in a sentence.
  @Published private(set) var lastError: String?
  @Published private(set) var counters: FlowObserverCounters

  var status: String { statusLine }

  /// The model's per-turn reply. Anything unparseable is treated as on-task/no-action so a flaky turn can never fire a
  /// bogus nudge.
  private struct Verdict: Decodable {
    let status: String?
    let action: String?
    let message: String?
    let reason: String?
    /// Short goal ids ("g2") the model saw finished on screen this turn.
    let completed_goals: [String]?
  }

  /// The optional second object in a reply: the model's revised timeline.
  private struct TimelineReply: Decodable {
    let timeline: [FlowSessionTimeline.ModelItem]?
  }

  // MARK: Collaborators

  private let setup: TBDFlowObserverSetup
  private let client: TBDFlowModelCompleting
  private let source: FlowScreenSource
  private let defaults: UserDefaults
  private let localCheck: (TBDFlowObserverRoute) async -> TBDFlowObserverError?
  private let frontApp: () -> FlowSessionTimeline.FrontApp
  private let now: () -> Date
  private let schedulesTimer: Bool
  private let tempRoot: URL
  private let settingsOverride: FlowAgentSettings?
  private let timelineOverride: FlowSessionTimeline?
  private let mirrorOverride: FlowSessionMirror?

  private var settings: FlowAgentSettings { settingsOverride ?? .shared }
  private var timeline: FlowSessionTimeline { timelineOverride ?? .shared }
  private var mirror: FlowSessionMirror { mirrorOverride ?? .shared }

  // MARK: State

  /// The session the mirror started (nil when idle). Kept while the switch is off, so turning it on mid-session works.
  private var session: FlowNativeSnapshot?
  private var tickTimer: Timer?
  private var tickInFlight = false
  private var paused = false
  /// True once the observer has passed its checks and looks at the screen on a timer.
  private(set) var isRunning = false
  /// Bumped on every start/stop so results from a superseded session's in-flight call are ignored when they land.
  private var generation = 0
  private var consecutiveFailures = 0
  /// One-shot context lines (snooze, back-to-work, break) folded into the next tick's message.
  private var pendingNotes: [String] = []
  private var lastReportedOffTask = false
  private var goalTasks: [TBDFlowGoal] = []
  private var reportedGoalIds: Set<String> = []
  private var alertStyle: FlowAlertStyle = .friendly
  private var sessionStartedAt = Date()
  private var sessionEndsAt: Date?
  private var workDirectory: URL?
  /// Debug panel: make the next tick ask for a timeline update.
  private var forceTimelineUpdate = false
  private var cancellables: Set<AnyCancellable> = []
  /// The start-up check (tests wait for it).
  private(set) var startTask: Task<Void, Never>?

  init(
    setup: TBDFlowObserverSetup = TBDFlowObserverSetup(), client: TBDFlowModelCompleting = TBDFlowModelClient(),
    source: FlowScreenSource = FlowSystemScreenSource(), settings: FlowAgentSettings? = nil,
    timeline: FlowSessionTimeline? = nil, mirror: FlowSessionMirror? = nil, defaults: UserDefaults = .standard,
    localCheck: @escaping (TBDFlowObserverRoute) async -> TBDFlowObserverError? = { await TBDFlowObserverSetup.localProblem(for: $0) },
    frontApp: @escaping () -> FlowSessionTimeline.FrontApp = { FlowSessionTimeline.frontmostApp() },
    now: @escaping () -> Date = { Date() }, schedulesTimer: Bool = true,
    tempRoot: URL = FileManager.default.temporaryDirectory
  ) {
    self.setup = setup
    self.client = client
    self.source = source
    self.settingsOverride = settings
    self.timelineOverride = timeline
    self.mirrorOverride = mirror
    self.defaults = defaults
    self.localCheck = localCheck
    self.frontApp = frontApp
    self.now = now
    self.schedulesTimer = schedulesTimer
    self.tempRoot = tempRoot
    self.counters = FlowObserverCounters.load(defaults, today: Self.dayKey(now()))
    statusLine = idleStatus
    if schedulesTimer {
      // A new cadence applies to the running session immediately.
      let source = settings ?? FlowAgentSettings.shared
      source.$tickSeconds
        .dropFirst()
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
          guard let self, self.isRunning else { return }
          self.scheduleTimer()
        }
        .store(in: &cancellables)
    }
  }

  private static func dayKey(_ date: Date) -> String { TBDFlowDay.string(from: date, calendar: .current) }

  private var idleStatus: String { setup.watching ? "Observer: waits for a session" : "Observer: off" }

  // MARK: - Lifecycle (driven by FlowSessionMirror phase transitions)

  func start(with snapshot: FlowNativeSnapshot, rebrief: Bool) {
    halt()
    session = snapshot
    if !rebrief {
      transcript = []
      reportedGoalIds = []
    }
    goalTasks = snapshot.goals
    alertStyle = snapshot.alertStyle
    sessionStartedAt = snapshot.sessionStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now()
    sessionEndsAt = snapshot.sessionEndsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    lastReportedOffTask = false
    lastOffTask = nil
    lastTickAt = nil
    lastError = nil
    pendingNotes = []
    consecutiveFailures = 0
    paused = snapshot.phase == .onBreak
    // Same session on a re-brief or relaunch keeps what's been logged so far.
    timeline.begin(sessionStartedAt: sessionStartedAt)
    begin()
  }

  /// The switch or the model setup changed: look again at whether the observer may run.
  func reconfigure() {
    // The mirror knows the truth (a break, a pause, an ended session), not the snapshot stored at the start.
    let current = mirror.snapshot
    guard current.phase == .active || current.phase == .onBreak else {
      session = nil
      halt()
      statusLine = idleStatus
      return
    }
    start(with: current, rebrief: true)
  }

  /// Starts watching when the switch is on, a session runs and a route resolves. Says why when it does not.
  private func begin() {
    guard session != nil else { statusLine = idleStatus; return }
    guard setup.watching else { statusLine = "Observer: off"; return }
    let route: TBDFlowObserverRoute
    do { route = try setup.resolve() } catch {
      fail(error.localizedDescription)
      return
    }
    // Nothing from an earlier run (a crash, a force quit) stays in the temp folder.
    Self.sweepLeftovers(in: tempRoot)
    let directory = tempRoot.appendingPathComponent(Self.workDirectoryPrefix + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    workDirectory = directory
    generation += 1
    let gen = generation
    statusLine = "Observer: starting"
    startTask = Task { [weak self] in
      guard let self else { return }
      // A local route needs Ollama and the model; say so before a check fails.
      if route.mode != .cloud, let problem = await self.localCheck(route) {
        guard gen == self.generation else { return }
        self.fail(problem.localizedDescription)
        return
      }
      guard gen == self.generation else { return }
      self.isRunning = true
      self.statusLine = self.paused ? "Observer: paused for your break" : "Observer: waits for the first check"
      if self.schedulesTimer { self.scheduleTimer() }
    }
  }

  /// The observer cannot run: stop the timer and keep the sentence for the page.
  private func fail(_ sentence: String) {
    halt()
    lastError = sentence
    statusLine = "Observer: " + sentence
  }

  func pause() {
    guard session != nil else { return }
    paused = true
    timeline.beginBreak(at: now())
    noteUserEvent("The user is taking a break; screenshots were paused while it lasted.")
    if isRunning { statusLine = "Observer: paused for your break" }
  }

  func resume() {
    guard session != nil else { return }
    paused = false
    timeline.endBreak(at: now())
    noteUserEvent("The user just came back from their break.")
    if isRunning { statusLine = lastCheckLine ?? "Observer: waits for the next check" }
  }

  /// The session ended or went idle.
  func stop() {
    session = nil
    halt()
    statusLine = idleStatus
  }

  /// Stops the timer and any in-flight result; removes the temp folder. The session facts stay.
  private func halt() {
    generation += 1
    tickTimer?.invalidate()
    tickTimer = nil
    tickInFlight = false
    isRunning = false
    startTask?.cancel()
    startTask = nil
    pendingNotes = []
    lastReportedOffTask = false
    cleanupWorkDirectory()
  }

  // MARK: - Debug panel controls

  /// Starts again with whatever the settings say now (model, prompt, cadence…).
  func restart() {
    let mirror = self.mirror
    guard mirror.snapshot.phase == .active || mirror.snapshot.phase == .onBreak else {
      appendTranscript("No active session to watch.")
      return
    }
    appendTranscript("Restarting the observer with the current settings.")
    start(with: mirror.snapshot, rebrief: true)
  }

  /// Takes a screenshot and asks the model right now, off the timer.
  @discardableResult
  func tickNow() -> Task<Void, Never>? {
    guard isRunning else {
      appendTranscript("The observer isn't running.")
      return nil
    }
    let wasPaused = paused
    paused = false
    let task = tick()
    paused = wasPaused
    return task
  }

  func clearTranscript() { transcript = [] }

  /// Debug panel: tick right now and ask for the timeline in the same turn.
  @discardableResult
  func requestTimelineNow() -> Task<Void, Never>? {
    forceTimelineUpdate = true
    return tickNow()
  }

  /// The briefing exactly as it would be sent now (for the debug panel).
  var currentBriefing: String { initialPrompt(evidence: (try? setup.resolve().evidence) ?? .text) }

  /// The open task list changed mid-session (voice additions, manual check-offs, a new alert style): tell the model on its
  /// next tick, with fresh short ids.
  func goalsChanged(to snapshot: FlowNativeSnapshot) {
    guard session != nil else { return }
    session = snapshot
    alertStyle = snapshot.alertStyle
    let next = snapshot.goals
    guard next != goalTasks else { return }
    let finished = goalTasks.filter { old in !next.contains(where: { $0.id == old.id }) }
    let added = next.filter { new in !goalTasks.contains(where: { $0.id == new.id }) }
    goalTasks = next
    var note = "GOALS UPDATED. Open goals are now:\n" + goalsList()
    if !finished.isEmpty {
      note += "\nNo longer open (done or removed): " + finished.map(\.title).joined(separator: "; ")
    }
    if !added.isEmpty {
      note += "\nNewly added: " + added.map(\.title).joined(separator: "; ")
    }
    if isRunning { pendingNotes.append(note) }
  }

  /// "- [g1] title" lines; the short id is the position in the current list.
  private func goalsList() -> String {
    goalTasks.enumerated().map { "- [g\($0.offset + 1)] \($0.element.title)" }.joined(separator: "\n")
  }

  /// Queue a line of context (snooze, back-to-work…) for the next tick. `markRefocused` also resets the off-task flag so
  /// a later distraction opens a fresh interval in the session log.
  func noteUserEvent(_ note: String, markRefocused: Bool) {
    guard isRunning else { return }
    pendingNotes.append(note)
    if markRefocused { lastReportedOffTask = false }
  }

  func userSnoozed() {
    updateCounters { $0.snoozes += 1 }
  }

  // MARK: - Ticks

  private func scheduleTimer() {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(withTimeInterval: max(5, settings.tickSeconds), repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.tick() }
    }
  }

  /// One check: capture, ask the model, act on the verdict. Returns the task for tests.
  @discardableResult
  func tick() -> Task<Void, Never>? {
    guard isRunning, !paused, !tickInFlight, session != nil, let directory = workDirectory else { return nil }
    // Resolved on every check: a mode switch, a withdrawn consent or a removed connection applies at once.
    let route: TBDFlowObserverRoute
    do { route = try setup.resolve() } catch {
      fail(error.localizedDescription)
      return nil
    }
    tickInFlight = true
    let gen = generation
    let askTimeline = forceTimelineUpdate || timeline.wantsUpdate(every: settings.timelineEverySeconds, at: now())
    forceTimelineUpdate = false
    let message = tickMessage(askTimeline: askTimeline)
    // The goal list this check sends; the model's "g2" is read against THIS list, not a later one.
    let sentGoals = goalTasks
    pendingNotes = []
    let history = transcript.suffix(6).map { $0.text }.joined(separator: "\n")
    let system =
      initialPrompt(evidence: route.evidence)
      + "\nThis is an HTTP observer with no tools or filesystem access. Return the verdict JSON first. If asked for a timeline, return the timeline JSON as a second object inline. Never claim to write a file. Prior observer verdicts (context only):\n"
      + history
    let shotURL = directory.appendingPathComponent("shot-\(Int(now().timeIntervalSince1970)).jpg")
    let height = settings.screenshotHeight
    let quality = settings.jpegQuality
    let timeout = settings.tickTimeoutSeconds
    let startedAt = now()
    // Which app is in front goes on the timeline entry (icon + merge key).
    let front = frontApp()
    let source = self.source
    let client = self.client

    let task = Task<Void, Never> { [weak self] in
      let outcome = await Self.fetch(
        source: source, client: client, route: route, system: system, message: message, shotURL: shotURL,
        height: height, quality: quality, timeout: timeout)
      self?.finishTick(
        generation: gen, reply: outcome.reply, error: outcome.error,
        seconds: Date().timeIntervalSince(startedAt), front: front, askedTimeline: askTimeline, sentGoals: sentGoals)
    }
    return task
  }

  /// Capture, read, call. Off the main actor. The capture lives in memory. Text mode reads it with Vision and never
  /// writes it or sends it. Image mode writes one JPEG to `shotURL` for the call and removes it on every path.
  private nonisolated static func fetch(
    source: FlowScreenSource, client: TBDFlowModelCompleting, route: TBDFlowObserverRoute, system: String,
    message: String, shotURL: URL, height: Int, quality: Double, timeout: TimeInterval
  ) async -> (reply: String?, error: String?) {
    defer { try? FileManager.default.removeItem(at: shotURL) }
    do {
      let image = try await source.captureImage(height: height)
      var prompt = message
      var jpeg: Data?
      switch route.evidence {
      case .text:
        let screenText = source.recognizeText(in: image)
        prompt += "\nScreen text (Apple OCR of the current screenshot):\n\(screenText)\nReply with the JSON object only."
      case .image:
        try source.writeJPEG(image, to: shotURL, quality: quality)
        jpeg = try Data(contentsOf: shotURL)
        prompt += "\nScreenshot attached. Reply with the JSON object only."
      }
      let reply = try await client.complete(
        system: system, userText: prompt, imageJPEG: jpeg, config: route.config, timeout: timeout)
      return (reply, nil)
    } catch {
      return (nil, error.localizedDescription)
    }
  }

  private func finishTick(
    generation gen: Int, reply: String?, error: String?, seconds: Double, front: FlowSessionTimeline.FrontApp,
    askedTimeline: Bool, sentGoals: [TBDFlowGoal]
  ) {
    guard gen == generation else { return }
    tickInFlight = false
    lastTickAt = now()
    lastTickSeconds = seconds

    guard let reply else {
      consecutiveFailures += 1
      lastError = error ?? "The check failed."
      appendTranscript("Turn failed: \(error ?? "unknown")")
      if consecutiveFailures >= settings.maxFailures {
        appendTranscript("The observer stopped after \(consecutiveFailures) failed checks.")
        let sentence = lastError ?? "The check failed."
        halt()
        lastError = sentence
        statusLine = "Observer stopped after \(consecutiveFailures) failed checks"
      }
      return
    }
    consecutiveFailures = 0
    lastError = nil
    appendTranscript(reply)

    let objects = Self.jsonObjects(in: reply)
    guard let first = objects.first, let verdict = try? JSONDecoder().decode(Verdict.self, from: Data(first.utf8)) else {
      // An unparseable reply is an on-task check with no action.
      updateCounters { $0.checks += 1 }
      lastOffTask = false
      refreshStatusAfterCheck()
      return
    }
    // The verdict comes first and is acted on first; the timeline (when the tick asked for one) rides behind it in a
    // second object.
    let offTask = verdict.status == "off_task"
    lastOffTask = offTask
    updateCounters {
      $0.checks += 1
      if offTask { $0.offPlanChecks += 1 }
    }
    handle(verdict: verdict, offTask: offTask, sentGoals: sentGoals)
    timeline.observe(offTask: offTask, front: front, reason: verdict.reason, at: now())
    if askedTimeline { readBackTimeline(objects) }
    refreshStatusAfterCheck()
  }

  /// "Last check 10:42 · on plan" (set after a real check, not before).
  private var lastCheckLine: String? {
    guard let at = lastTickAt, let off = lastOffTask else { return nil }
    return "Last check " + at.formatted(.dateTime.hour().minute()) + (off ? " · off plan" : " · on plan")
  }

  private func refreshStatusAfterCheck() {
    guard isRunning else { return }
    statusLine = paused ? "Observer: paused for your break" : (lastCheckLine ?? statusLine)
  }

  /// After a timeline turn: take the `{"timeline": [...]}` object the model wrote after its verdict.
  private func readBackTimeline(_ objects: [String]) {
    for object in objects {
      if let parsed = try? JSONDecoder().decode(TimelineReply.self, from: Data(object.utf8)), let items = parsed.timeline {
        timeline.apply(modelItems: items, at: now())
        return
      }
    }
    appendTranscript("Timeline update: the model didn't leave a usable timeline.")
  }

  private func handle(verdict: Verdict, offTask: Bool, sentGoals: [TBDFlowGoal]) {
    if offTask != lastReportedOffTask {
      lastReportedOffTask = offTask
      mirror.agentReportedFocusChange(isDistracted: offTask)
    }

    // Goals the model saw finished: resolve g-ids against the list that check sent, relay once each. FlowPlanner ticks them off (one entry point).
    let finished = (verdict.completed_goals ?? []).compactMap { short -> TBDFlowGoal? in
      let digits = short.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "g[] "))
      guard let index = Int(digits), index >= 1, index <= sentGoals.count else { return nil }
      let task = sentGoals[index - 1]
      guard !reportedGoalIds.contains(task.id) else { return nil }
      return task
    }
    if !finished.isEmpty {
      reportedGoalIds.formUnion(finished.map(\.id))
      mirror.agentCompletedGoals(finished)
    }

    switch verdict.action {
    case "nudge":
      let message = verdict.message.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Psst... I think you're getting distracted!")
      if alertStyle != .quiet { updateCounters { $0.nudges += 1 } }
      mirror.agentNudge(message: message)
    case "praise":
      if let message = verdict.message, !message.isEmpty {
        mirror.agentPraise(message: message)
      }
    default:
      break
    }
  }

  private func updateCounters(_ change: (inout FlowObserverCounters) -> Void) {
    var current = FlowObserverCounters.load(defaults, today: Self.dayKey(now()))
    change(&current)
    current.save(defaults)
    counters = current
  }

  /// The counters for the page (rolls over at midnight).
  func refreshCounters() {
    counters = FlowObserverCounters.load(defaults, today: Self.dayKey(now()))
  }

  // MARK: - Prompts

  private func initialPrompt(evidence: TBDFlowObserverEvidence) -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let started = timeFormatter.string(from: sessionStartedAt)

    let lengthLine: String
    if let endsAt = sessionEndsAt {
      let minutes = max(1, Int(endsAt.timeIntervalSince(sessionStartedAt) / 60))
      lengthLine = "Planned length: \(minutes) minutes (ends around \(timeFormatter.string(from: endsAt)))."
    } else {
      lengthLine = "Open-ended: no timer, the user works until they choose to stop."
    }

    let goalsBlock: String
    if goalTasks.isEmpty {
      goalsBlock = """
        The user didn't list specific goals. Judge by continuity instead: sustained work in \
        one arena (coding, writing, design, research...) is on task; entertainment, social \
        feeds, and aimless browsing are off task.
        """
    } else {
      goalsBlock = goalsList()
    }

    let styleBlock: String
    switch alertStyle {
    case .quiet:
      styleBlock = """
        Quiet. The user asked for zero interruptions. NEVER use "nudge" or "praise" — keep \
        action "none" on every turn. Your status field still matters: distractions are \
        logged silently for their session summary.
        """
    case .friendly:
      styleBlock = """
        Friendly. Give them slack: don't nudge until they've clearly been off task for a \
        few minutes straight (many consecutive off-task checks — a quick detour that \
        ends on its own never earns a nudge). One nudge per incident; if they're still \
        distracted several minutes later, one firmer follow-up is okay. Tone: warm and \
        encouraging, like a supportive friend. Never guilt-trippy.
        """
    case .feisty:
      styleBlock = """
        Feisty. Quick and stern. Nudge as soon as you're confident they're off task — one \
        clearly off-task check is enough. Persistent reminders until they're back on \
        track: if they stay distracted, nudge again every minute or two, each one more \
        direct than the last. Tone: stern and no-nonsense, a coach who won't let it slide. \
        Blunt is fine; insulting is not.
        """
    }

    // The evidence wording flips between screenshots and OCR text.
    let evidenceIntro: String
    let evidenceJudging: String
    switch evidence {
    case .text:
      evidenceIntro =
        "text extracted from a screenshot of their screen (Apple's OCR), the current time, and the time left"
      evidenceJudging = """
        - The OCR text is your only evidence, and it's imperfect: expect garbled fragments, \
        menu bars, timestamps, and UI chrome mixed together. Anchor on the strong signals — \
        app names, window and tab titles, site names, video or post titles.
        """
    case .image:
      evidenceIntro = "a screenshot of their screen, the current time, and the time left"
      evidenceJudging = "- The screenshot is your only evidence."
    }

    let template = settings.briefingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    var prompt = template.isEmpty ? Self.briefingTemplate : template
    let values: [String: String] = [
      "{{started}}": started,
      "{{length}}": lengthLine,
      "{{style}}": alertStyle.rawValue,
      "{{goals}}": goalsBlock,
      "{{style_rules}}": styleBlock,
      "{{evidence_intro}}": evidenceIntro,
      "{{evidence_rules}}": evidenceJudging,
      "{{tick_seconds}}": String(Int(settings.tickSeconds)),
    ]
    for (key, value) in values {
      prompt = prompt.replacingOccurrences(of: key, with: value)
    }
    let extra = settings.extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !extra.isEmpty {
      prompt += "\n\nADDITIONAL INSTRUCTIONS\n" + extra
    }
    return prompt
  }

  /// The built-in briefing. Placeholders: {{started}}, {{length}}, {{style}}, {{goals}}, {{style_rules}},
  /// {{evidence_intro}}, {{evidence_rules}}, {{tick_seconds}}. The debug panel can replace the whole thing. v1 text; TBD
  /// replaces "Dayflow" and the timeline file hand-off (the timeline now comes back as a second JSON object).
  static let briefingTemplate = """
    You are the focus companion inside TBD, a Mac app. The user just \
    started a Flow focus session and you're watching over it. Roughly every {{tick_seconds}} seconds \
    you'll get a message with {{evidence_intro}}. Your job: judge whether they're on task, \
    and decide whether their focus buddy (a small pixel creature that peeks in from the \
    screen edge) should say something.

    SESSION
    - Started at {{started}}.
    - {{length}}
    - Alert style: {{style}}.

    THE USER'S STATED FOCUS
    {{goals}}

    HOW TO JUDGE
    - Be generous. Docs, searches, terminal work, Slack or email replies, and quick \
    utility checks all plausibly serve the goals — count them as on task.
    - One glance at something unrelated is not a distraction; a pattern across \
    consecutive checks is (social feeds, YouTube, shopping, news rabbit holes).
    {{evidence_rules}}
    - If you're unsure, assume on task.

    HOW TO REPLY
    Reply to every message with exactly one JSON object and nothing else — no prose, no \
    code fences, no explanation:
    {"status": "on_task" | "off_task", "action": "none" | "nudge" | "praise", "message": "...", "reason": "..."}
    - status: your read of the current check.
    - action "nudge" makes the creature appear with your message. Write it yourself in \
    the alert style's tone, but keep it SHORT: one sentence, 10 words max — it renders \
    in a tiny speech bubble ("Twitter can wait — 12 minutes left!").
    - action "praise" shows a brief encouragement, same 10-word cap. Use it sparingly — \
    at most once every ten minutes or so, e.g. after a long on-task stretch or right \
    after they recover from a distraction.
    - message is required whenever action isn't "none". reason: a few words of evidence \
    whenever status is "off_task".
    - completed_goals: optional. Each goal above has a short id in brackets. When the \
    screen shows a goal has been FINISHED — the PR is merged, the email is in Sent, the \
    doc is published, the ticket is closed, they typed "done" — include its id, e.g. \
    "completed_goals": ["g2"], in that turn's verdict. Working on a goal is not finishing \
    it: only report on clear evidence of completion, and report each goal once. TBD \
    checks the task off for them, so a false positive is worse than a miss.

    ALERT STYLE
    {{style_rules}}

    THE SESSION TIMELINE
    You also keep the user's session log, the way TBD's timeline does: a JSON array of \
    entries {"start": "HH:mm", "end": "HH:mm", "kind": "focused" | "distracted" | "break", "title": "..."}. \
    About once a minute a message will end with "TIMELINE UPDATE" and give you the current \
    timeline plus the check log since your last update. On those turns, reply with the \
    verdict object first, then a second JSON object on its own, {"timeline": [ ... ]}, \
    holding the whole revised array — usually extend the last entry or add one for what \
    they've moved on to, and now and then condense: merge a stretch of work on one thing \
    into a single entry even if they bounced between docs, terminal, and editor for it, and \
    rename earlier entries once you understand what they were really doing. Keep genuine \
    splits: a detour to X or YouTube (kind "distracted"), even a one-minute one, and every \
    break stay as their own entries. Entries must stay contiguous (each starts where the \
    previous ended, 24h HH:mm), the first at the session start, the last ending at the \
    current time. Titles are concrete, 3–7 words, like "Address feedback on PR", \
    "Scrolling on X", "Reviewing checkout flow mockups in Figma". On every other turn reply \
    with the verdict object only.

    Don't overthink the ticks: no analysis, no chain of reasoning in your reply. Most \
    turns the correct answer is exactly {"status":"on_task","action":"none"}. Acknowledge \
    this briefing now with that same JSON object.
    """

  private func tickMessage(askTimeline: Bool) -> String {
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    let current = now()

    var line = "Current time: \(timeFormatter.string(from: current))."
    if let endsAt = sessionEndsAt {
      let remaining = max(0, Int(endsAt.timeIntervalSince(current) / 60))
      line += " Time remaining: \(Self.formatMinutes(remaining))."
    } else {
      let elapsed = max(0, Int(current.timeIntervalSince(sessionStartedAt) / 60))
      line += " Elapsed: \(Self.formatMinutes(elapsed)) (open-ended session)."
    }

    var parts = [line]
    parts.append(contentsOf: pendingNotes)
    if askTimeline {
      let since = timeline.lastModelUpdateAt
      parts.append(
        """
        TIMELINE UPDATE — after the verdict object, add a second JSON object {"timeline": [...]} with the whole \
        revised timeline, covering the session (started \(FlowSessionTimeline.clock(sessionStartedAt))) up to now.
        Current timeline:
        \(timeline.promptTimelineJSON())
        Check log since your last update (time · verdict · frontmost app · reason):
        \(timeline.promptObservations(since: since))
        Breaks (exact, from the app): \(timeline.promptBreaks())
        """)
    }
    // The evidence line (screenshot vs OCR text) is appended in tick(), where the capture happens.
    return parts.joined(separator: "\n")
  }

  private static func formatMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
  }

  private func appendTranscript(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    transcript.append(TranscriptEntry(date: now(), text: trimmed))
    if transcript.count > 200 {
      transcript.removeFirst(transcript.count - 200)
    }
  }

  // MARK: - Verdict parsing

  /// Every top-level {...} in the reply, in order, tolerating fences and stray prose around them. Strings are skipped so
  /// braces inside a title don't confuse the depth count.
  static func jsonObjects(in reply: String) -> [String] {
    var objects: [String] = []
    var depth = 0
    var start: String.Index?
    var inString = false
    var escaped = false
    var index = reply.startIndex
    while index < reply.endIndex {
      let character = reply[index]
      if inString {
        if escaped {
          escaped = false
        } else if character == "\\" {
          escaped = true
        } else if character == "\"" {
          inString = false
        }
      } else if character == "\"" {
        inString = true
      } else if character == "{" {
        if depth == 0 { start = index }
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0, let begin = start {
          objects.append(String(reply[begin...index]))
          start = nil
        }
        if depth < 0 { depth = 0 }
      }
      index = reply.index(after: index)
    }
    return objects
  }

  // MARK: - Cleanup

  /// The temp folder of the screenshots (one file lives in it while a check runs, and is removed after the check).
  private func cleanupWorkDirectory() {
    if let directory = workDirectory {
      try? FileManager.default.removeItem(at: directory)
    }
    workDirectory = nil
    Self.sweepLeftovers(in: tempRoot)
  }

  static let workDirectoryPrefix = "TBDFlowObserver-"

  /// Removes every `TBDFlowObserver-*` folder in `root` (the observer's own screenshot folders, left by a run that did
  /// not end cleanly). Called when the observer starts and when it stops.
  static func sweepLeftovers(in root: URL) {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
    for name in names where name.hasPrefix(workDirectoryPrefix) {
      try? fileManager.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
    }
  }

  /// Design shots only: shows a state the page has after some checks, without running any.
  func showPreview(lastCheckAt: Date, offTask: Bool, counters preview: FlowObserverCounters) {
    lastTickAt = lastCheckAt
    lastOffTask = offTask
    isRunning = true
    preview.save(defaults)
    counters = preview
    statusLine = lastCheckLine ?? statusLine
  }

  /// For tests: where the screenshots go.
  var workDirectoryForTests: URL? { workDirectory }
}
