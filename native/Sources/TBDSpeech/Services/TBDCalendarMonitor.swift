import EventKit
import Foundation

/// Watches the user's calendars for upcoming meetings (EventKit, local only).
/// Reports each meeting once a minute before it starts and once when it starts.
public final class TBDCalendarMonitor: @unchecked Sendable {
    public struct Meeting: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let start: Date
        public let end: Date
        /// Identifies a repeating series (or the single event).
        public var seriesID: String = ""
        public var recurring = false
    }

    /// `upcoming` a minute before; `started` from 5 s before the start until 30 s after (auto-start window).
    public enum Event: Sendable { case upcoming(Meeting), started(Meeting) }

    private let store = EKEventStore()
    private var timer: DispatchSourceTimer?
    private var notified: [String: Set<String>] = [:]
    private let queue = DispatchQueue(label: "com.tealbrick.desktop.calendar")
    public var onEvent: (@Sendable (Event) -> Void)?

    public init() {}

    public static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Meetings in the next `hours` hours (for the UI).
    public func upcoming(hours: Double = 12) -> [Meeting] {
        guard Self.authorized else { return [] }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-15 * 60), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate).filter(Self.isMeeting).filter { $0.endDate > now }.map(Self.meeting)
            .sorted { $0.start < $1.start }
    }

    private var lastFullPoll = Date.distantPast

    /// Ticks every 5 s; reads the calendar every 60 s, or every tick when a meeting starts within 2 minutes.
    private func poll() {
        guard Self.authorized else { return }
        let now = Date()
        if now.timeIntervalSince(lastFullPoll) < 55, !soon(now) { return }
        lastFullPoll = now
        cached = upcoming(hours: 0.25)
        for meeting in cached {
            let untilStart = meeting.start.timeIntervalSince(now)
            if untilStart <= 60, untilStart > 5 { fire(.upcoming(meeting), key: "upcoming", meeting: meeting) }
            if untilStart <= 5, untilStart > -30 { fire(.started(meeting), key: "started", meeting: meeting) }
        }
    }

    private var cached: [Meeting] = []
    private func soon(_ now: Date) -> Bool { cached.contains { abs($0.start.timeIntervalSince(now)) <= 120 } }

    private func fire(_ event: Event, key: String, meeting: Meeting) {
        let id = meeting.id + "@" + String(Int(meeting.start.timeIntervalSince1970))
        guard notified[id, default: []].insert(key).inserted else { return }
        onEvent?(event)
    }

    static func isMeeting(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.availability != .free else { return false }
        if (event.attendees?.count ?? 0) >= 2 { return true }
        let text = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        return ["zoom.us", "meet.google.com", "teams.microsoft.com", "webex.com", "whereby.com", "facetime"].contains { text.contains($0) }
    }

    static func meeting(_ event: EKEvent) -> Meeting {
        Meeting(id: event.calendarItemIdentifier, title: event.title ?? "Meeting", start: event.startDate, end: event.endDate,
                seriesID: event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier, recurring: event.hasRecurrenceRules)
    }
}
