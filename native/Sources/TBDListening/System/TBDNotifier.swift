import AppKit
import OSLog
import TBDSpeech
import UserNotifications

/// The notification centre as far as the notifier needs it. A fake stands in for it in tests.
protocol TBDNotificationCenter {
    /// True when banners may be shown; asks once if the person has not decided.
    func isAuthorized() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

struct TBDSystemNotificationCenter: TBDNotificationCenter {
    func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default: return false
        }
    }
    func add(_ request: UNNotificationRequest) async throws { try await UNUserNotificationCenter.current().add(request) }
}

/// Plays the completion chime and, when TBD is in the background, shows a silent banner (v1
/// `TranscriptionCompletionPresenter`; the chime is the audible cue, so the banner has no sound).
@MainActor
final class TBDNotifier {
    private let center: () -> TBDNotificationCenter
    private let isAppActive: @MainActor () -> Bool
    private let chime: @MainActor () -> Void
    private let log = Logger(subsystem: "com.tealbrick.desktop", category: "Notifications")

    init(center: @escaping () -> TBDNotificationCenter = { TBDSystemNotificationCenter() },
         isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
         chime: @escaping @MainActor () -> Void = { TBDSounds.shared.play(.complete) }) {
        self.center = center; self.isAppActive = isAppActive; self.chime = chime
    }

    /// The request for a banner: title and body from the notice, no sound, delivered at once.
    static func request(for content: TBDCompletionNotice.Content, id: String = UUID().uuidString) -> UNNotificationRequest {
        let body = UNMutableNotificationContent()
        body.title = content.title
        body.body = content.body
        body.sound = nil
        return UNNotificationRequest(identifier: "tbd.listening.transcription.\(id)", content: body, trigger: nil)
    }

    /// Chime always; banner only while TBD is in the background. Returns the banner task so tests can wait for it.
    @discardableResult
    func present(_ content: TBDCompletionNotice.Content) -> Task<Void, Never>? {
        chime()
        guard !isAppActive() else { return nil }
        return post(content)
    }

    @discardableResult
    func post(_ content: TBDCompletionNotice.Content) -> Task<Void, Never> {
        let center = center()
        return Task { [log] in
            guard await center.isAuthorized() else { log.info("banner skipped: notifications not allowed"); return }
            do { try await center.add(Self.request(for: content)) } catch { log.error("banner failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
