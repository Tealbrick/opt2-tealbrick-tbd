//
//  FlowSessionTimeline.swift
//  TBD
//
//  The session's activity timeline for the summary screen, written by the
//  distraction agent's model the way Dayflow's timeline cards are: not one
//  row per screenshot, but a grouping the model revises as it goes. About
//  once a minute a tick asks for the full timeline so far; the model folds
//  in the latest checks and condenses earlier stretches with hindsight
//  (merging same-work blocks, keeping short detours and breaks as their own
//  splits). Native validates the result, pins the exact break spans it
//  knows about, attaches app icons from its per-tick observations, and
//  writes everything to a JSON file in TBD's own data folder (`com.tealbrick.desktop`, never the archived v1 `TBD`
//  folder). When the session ends the summary takes
//  whatever the last update produced — no extra model turn.
//

import AppKit
import Foundation
import TBDModels

@MainActor
final class FlowSessionTimeline: ObservableObject {
  static let shared = FlowSessionTimeline()

  enum Kind: String, Codable {
    case focused
    case distracted
    case `break`
  }

  /// One row of the summary log.
  struct Entry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var kind: Kind
    var startedAt: Date
    var endedAt: Date
    /// Frontmost app's icon as a data: URL (32px PNG), when we had one.
    var iconURL: String?
  }

  /// What native saw on one tick: the model's verdict plus the frontmost app.
  struct Observation: Codable, Equatable {
    var at: Date
    var offTask: Bool
    var bundleId: String?
    var appName: String?
    var reason: String?
  }

  /// A timeline item as the model writes it (times as 24h "HH:mm").
  struct ModelItem: Decodable {
    let start: String?
    let end: String?
    let title: String?
    let kind: String?
  }

  private struct File: Codable {
    var sessionStartedAt: Date
    var updatedAt: Date
    var entries: [Entry]
    var observations: [Observation]
    var breaks: [Span]
  }

  struct Span: Codable, Equatable {
    var start: Date
    var end: Date?
  }

  @Published private(set) var entries: [Entry] = []
  @Published private(set) var observations: [Observation] = []
  private(set) var breaks: [Span] = []
  private(set) var sessionStartedAt = Date()
  private(set) var updatedAt: Date?
  /// When the model last delivered a timeline (drives the once-a-minute ask).
  private(set) var lastModelUpdateAt: Date?

  /// `~/Library/Application Support/<TBD data folder>/Companion/flow-session-timeline.json`.
  nonisolated static var defaultFileURL: URL {
    TBDIdentity.applicationSupport("Companion").appendingPathComponent("flow-session-timeline.json")
  }

  /// Where the timeline lives on disk.
  let fileURL: URL

  init(fileURL: URL = FlowSessionTimeline.defaultFileURL) {
    self.fileURL = fileURL
  }

  // MARK: - Session lifecycle

  /// Called when the agent starts watching a session. Keeps what's on disk
  /// if it belongs to this same session (a relaunch or re-brief); otherwise
  /// starts empty.
  func begin(sessionStartedAt started: Date) {
    if let file = load(), abs(file.sessionStartedAt.timeIntervalSince(started)) < 5 {
      sessionStartedAt = file.sessionStartedAt
      entries = file.entries
      observations = file.observations
      breaks = file.breaks
      updatedAt = file.updatedAt
      lastModelUpdateAt = file.entries.isEmpty ? nil : file.updatedAt
      return
    }
    sessionStartedAt = started
    entries = []
    observations = []
    breaks = []
    updatedAt = nil
    lastModelUpdateAt = nil
    save()
  }

  /// Every tick's verdict lands here, timeline update or not.
  func observe(offTask: Bool, front: FrontApp, reason: String?, at now: Date = Date()) {
    observations.append(
      Observation(
        at: now, offTask: offTask, bundleId: front.bundleId, appName: front.name,
        reason: reason))
    if observations.count > 2000 { observations.removeFirst(observations.count - 2000) }
    save()
  }

  func beginBreak(at now: Date = Date()) {
    if let last = breaks.last, last.end == nil { return }
    breaks.append(Span(start: now, end: nil))
    save()
  }

  func endBreak(at now: Date = Date()) {
    guard var last = breaks.last, last.end == nil else { return }
    last.end = now
    breaks[breaks.count - 1] = last
    save()
  }

  /// Whether the next tick should ask the model for a timeline update.
  func wantsUpdate(every interval: TimeInterval, at now: Date = Date()) -> Bool {
    guard let last = lastModelUpdateAt else {
      // First one once there's a minute of session to describe.
      return now.timeIntervalSince(sessionStartedAt) >= min(interval, 60)
    }
    return now.timeIntervalSince(last) >= interval
  }

  /// The model's revised timeline. Times come as "HH:mm" on the session's
  /// day; entries are sorted, clamped to the session, snapped so they're
  /// contiguous, cut around the exact break spans, and given icons.
  func apply(modelItems: [ModelItem], at now: Date = Date()) {
    var parsed: [Entry] = []
    for item in modelItems {
      guard let title = item.title.map(Self.tidy), !title.isEmpty,
        let start = date(fromClock: item.start, near: now),
        let end = date(fromClock: item.end, near: now)
      else { continue }
      let kind = Kind(rawValue: (item.kind ?? "").lowercased()) ?? .focused
      parsed.append(
        Entry(
          id: UUID().uuidString, title: title, kind: kind,
          startedAt: max(sessionStartedAt, start), endedAt: min(now, max(start, end)),
          iconURL: nil))
    }
    parsed.sort { $0.startedAt < $1.startedAt }
    // Contiguous: each entry starts where the previous ended; drop empties.
    var cursor = sessionStartedAt
    var contiguous: [Entry] = []
    for var entry in parsed {
      entry.startedAt = max(cursor, min(entry.startedAt, now))
      entry.endedAt = max(entry.startedAt, entry.endedAt)
      guard entry.endedAt > entry.startedAt else { continue }
      contiguous.append(entry)
      cursor = entry.endedAt
    }
    guard !contiguous.isEmpty else { return }
    var result = overlayBreaks(on: contiguous, until: now)
    for index in result.indices where result[index].kind != .break {
      result[index].iconURL = iconForSpan(result[index].startedAt, result[index].endedAt)
    }
    entries = result
    lastModelUpdateAt = now
    save()
  }

  /// The session is over: the last entry runs to the end so the final bar
  /// doesn't stop a tick short. No model turn — we show what we have.
  func finish(at now: Date = Date()) {
    endBreak(at: now)
    trimObservations(at: now)
    guard var last = entries.last, last.endedAt < now,
      now.timeIntervalSince(last.endedAt) < 15 * 60
    else {
      save()
      return
    }
    last.endedAt = now
    entries[entries.count - 1] = last
    save()
  }

  /// At the end of a session the file keeps only this session's checks, and only today's short check notes (the reasons):
  /// a check from before the session is dropped, and a reason from before today is cleared. The entries stay as they are.
  private func trimObservations(at now: Date) {
    let startOfToday = Calendar.current.startOfDay(for: now)
    observations = observations.filter { $0.at >= sessionStartedAt }.map { observation in
      guard observation.at < startOfToday, observation.reason != nil else { return observation }
      var kept = observation
      kept.reason = nil
      return kept
    }
  }

  func clear() {
    entries = []
    observations = []
    breaks = []
    updatedAt = nil
    lastModelUpdateAt = nil
    save()
  }

  // MARK: - Prompt material

  /// The current timeline as the model last wrote it, for revision.
  func promptTimelineJSON() -> String {
    guard !entries.isEmpty else { return "[]" }
    let rows = entries.map { entry in
      "{\"start\":\"\(Self.clock(entry.startedAt))\",\"end\":\"\(Self.clock(entry.endedAt))\","
        + "\"kind\":\"\(entry.kind.rawValue)\",\"title\":\(Self.jsonString(entry.title))}"
    }
    return "[\n" + rows.joined(separator: ",\n") + "\n]"
  }

  /// Native's per-tick log since the last timeline update, one line each.
  func promptObservations(since: Date?) -> String {
    let recent = observations.filter { since == nil || $0.at > since! }
    guard !recent.isEmpty else { return "(no checks since the last update)" }
    return recent.map { observation in
      var line = "\(Self.clock(observation.at)) \(observation.offTask ? "off_task" : "on_task")"
      if let app = observation.appName { line += " · \(app)" }
      if let reason = observation.reason, !reason.isEmpty { line += " · \(reason)" }
      return line
    }.joined(separator: "\n")
  }

  func promptBreaks() -> String {
    guard !breaks.isEmpty else { return "(none)" }
    return breaks.map { span in
      "\(Self.clock(span.start))–\(span.end.map(Self.clock) ?? "ongoing")"
    }.joined(separator: ", ")
  }

  // MARK: - App icons

  struct FrontApp {
    var bundleId: String?
    var name: String?
    var iconURL: String?
    static let none = FrontApp()
  }

  /// The frontmost app right now, with its icon as a small PNG data URL.
  nonisolated static func frontmostApp() -> FrontApp {
    guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
    // TBD's own overlay/window in front tells us nothing about the work.
    if app.bundleIdentifier == Bundle.main.bundleIdentifier { return .none }
    return FrontApp(
      bundleId: app.bundleIdentifier, name: app.localizedName, iconURL: iconDataURL(for: app))
  }

  private nonisolated(unsafe) static var iconCache: [String: String] = [:]
  private nonisolated static let iconCacheLock = NSLock()

  private nonisolated static func iconDataURL(for app: NSRunningApplication) -> String? {
    let key = app.bundleIdentifier ?? app.localizedName ?? ""
    iconCacheLock.lock()
    if let cached = iconCache[key] {
      iconCacheLock.unlock()
      return cached
    }
    iconCacheLock.unlock()
    guard let icon = app.icon else { return nil }
    let size = NSSize(width: 32, height: 32)
    let small = NSImage(size: size)
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(
      in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let url = "data:image/png;base64," + png.base64EncodedString()
    iconCacheLock.lock()
    iconCache[key] = url
    iconCacheLock.unlock()
    return url
  }

  /// Icon of the app most often in front during a span.
  private func iconForSpan(_ start: Date, _ end: Date) -> String? {
    var counts: [String: Int] = [:]
    for observation in observations
    where observation.at >= start && observation.at <= end && observation.bundleId != nil {
      counts[observation.bundleId!, default: 0] += 1
    }
    guard let bundleId = counts.max(by: { $0.value < $1.value })?.key else { return nil }
    Self.iconCacheLock.lock()
    let cached = Self.iconCache[bundleId]
    Self.iconCacheLock.unlock()
    if let cached { return cached }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first
    else { return nil }
    return Self.iconDataURL(for: app)
  }

  // MARK: - Breaks

  /// Native knows exactly when breaks happened; cut them into the model's
  /// entries so break bars are precise whatever the model wrote.
  private func overlayBreaks(on entries: [Entry], until now: Date) -> [Entry] {
    var result = entries.filter { $0.kind != .break }
    for span in breaks {
      let breakStart = span.start
      let breakEnd = min(now, span.end ?? now)
      guard breakEnd > breakStart else { continue }
      var next: [Entry] = []
      for entry in result {
        if entry.endedAt <= breakStart || entry.startedAt >= breakEnd {
          next.append(entry)
          continue
        }
        if entry.startedAt < breakStart {
          var head = entry
          head.endedAt = breakStart
          next.append(head)
        }
        if entry.endedAt > breakEnd {
          var tail = entry
          tail.id = UUID().uuidString
          tail.startedAt = breakEnd
          next.append(tail)
        }
      }
      next.append(
        Entry(
          id: UUID().uuidString, title: "Break", kind: .break, startedAt: breakStart,
          endedAt: breakEnd, iconURL: nil))
      result = next.sorted { $0.startedAt < $1.startedAt }
    }
    return result
  }

  // MARK: - Helpers

  private static let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

  /// "HH:mm" (or "h:mm a") on the session's day, choosing the day so the
  /// result lands nearest the session (handles a session crossing midnight).
  private func date(fromClock text: String?, near now: Date) -> Date? {
    guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    var hour = 0
    var minute = 0
    let lower = text.lowercased()
    let digits = lower.replacingOccurrences(of: "am", with: "").replacingOccurrences(
      of: "pm", with: ""
    ).trimmingCharacters(in: .whitespaces)
    let parts = digits.split(separator: ":")
    guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) else {
      return nil
    }
    hour = h
    minute = m
    if lower.contains("pm"), hour < 12 { hour += 12 }
    if lower.contains("am"), hour == 12 { hour = 0 }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    let calendar = Calendar.current
    let candidates = [-1, 0, 1].compactMap { offset -> Date? in
      guard let day = calendar.date(byAdding: .day, value: offset, to: sessionStartedAt) else {
        return nil
      }
      return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
    let middle = sessionStartedAt.addingTimeInterval(now.timeIntervalSince(sessionStartedAt) / 2)
    return candidates.min { abs($0.timeIntervalSince(middle)) < abs($1.timeIntervalSince(middle)) }
  }

  private static func tidy(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix(".") { text.removeLast() }
    if text.count > 60 { text = String(text.prefix(57)) + "…" }
    guard let first = text.first else { return "" }
    return first.uppercased() + text.dropFirst()
  }

  private static func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
  }

  private func save() {
    updatedAt = Date()
    let file = File(
      sessionStartedAt: sessionStartedAt, updatedAt: updatedAt!, entries: entries,
      observations: observations, breaks: breaks)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(file) else { return }
    let directory = fileURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: directory.path) {
      try? fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    // Mode 0600 from the first byte: a temp file with that mode, then a rename over the old file.
    let temp = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
    guard fileManager.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
    if rename(temp.path, fileURL.path) != 0 {
      try? fileManager.removeItem(at: temp)  // our own temp file
    }
  }

  private func load() -> File? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(File.self, from: data)
  }
}
