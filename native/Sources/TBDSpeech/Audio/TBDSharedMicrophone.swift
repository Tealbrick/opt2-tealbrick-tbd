import AVFoundation
import Foundation
import os
import TBDSpeechObjC

/// One microphone stream for the whole process: one AVAudioEngine, one input tap, many subscribers.
/// The engine starts with the first subscriber, stops with the last, follows the System Default input
/// (or a chosen device) and restarts itself after route or format changes.
public final class TBDSharedMicrophone: @unchecked Sendable {
    public static let shared = TBDSharedMicrophone()
    public typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void
    public struct Token: Hashable, Sendable { let id = UUID() }

    private struct Subscriber { let handler: Handler; let onInterruption: (@Sendable (Error) -> Void)? }

    private let log = Logger(subsystem: "com.tealbrick.desktop", category: "Microphone")
    private let queue = DispatchQueue(label: "com.tealbrick.desktop.microphone")
    private let snapshotLock = NSLock()
    private var handlers: [Handler] = []
    private var subscribers: [Token: Subscriber] = [:]
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var restartGeneration = 0
    private var preferredUID: String?

    public init() {}

    /// Device UID to capture from, or nil for the System Default input. Applies on the next (re)start.
    public func setPreferredDevice(uid: String?) {
        queue.async {
            guard self.preferredUID != uid else { return }
            self.preferredUID = uid
            if !self.subscribers.isEmpty { self.scheduleRestart(after: 0) }
        }
    }

    public var isRunning: Bool { queue.sync { engine?.isRunning == true } }

    /// The device the stream uses now (or would use on start).
    public var currentDeviceName: String {
        let uid = queue.sync { preferredUID }
        if let uid, let input = TBDAudioDevices.input(uid: uid) { return input.name }
        return TBDAudioDevices.defaultInput()?.name ?? "System Default"
    }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Adds a subscriber. Buffers arrive on the tap thread in the device format; handlers must be quick.
    public func subscribe(onInterruption: (@Sendable (Error) -> Void)? = nil, handler: @escaping Handler) async throws -> Token {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Token, Error>) in
            queue.async {
                let token = Token()
                self.subscribers[token] = Subscriber(handler: handler, onInterruption: onInterruption)
                self.refreshSnapshot()
                guard self.engine == nil else { continuation.resume(returning: token); return }
                do {
                    try self.startEngine()
                    continuation.resume(returning: token)
                } catch {
                    self.subscribers[token] = nil
                    self.refreshSnapshot()
                    continuation.resume(throwing: TBDSpeechError.microphoneUnavailable(error.localizedDescription))
                }
            }
        }
    }

    public func unsubscribe(_ token: Token) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.subscribers[token] = nil
                self.refreshSnapshot()
                if self.subscribers.isEmpty { self.stopEngine() }
                continuation.resume()
            }
        }
    }

    // MARK: - Engine (queue only)

    private func refreshSnapshot() {
        let current = subscribers.values.map(\.handler)
        snapshotLock.lock(); handlers = current; snapshotLock.unlock()
    }

    private func deliver(_ buffer: AVAudioPCMBuffer) {
        snapshotLock.lock(); let current = handlers; snapshotLock.unlock()
        for handler in current { handler(buffer) }
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = preferredUID, let device = TBDAudioDevices.input(uid: uid) {
            if !TBDAudioDevices.select(device.id, on: engine) { log.error("mic_select_device_failed") }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TBDSpeechError.microphoneUnavailable("no input device")
        }
        var objcError: NSError?
        let installed = TBDCatchObjCException({
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.deliver(buffer)
            }
        }, &objcError)
        guard installed else { throw objcError ?? TBDSpeechError.microphoneUnavailable("tap failed") }
        engine.prepare()
        var startError: Error?
        let started = TBDCatchObjCException({
            do { try engine.start() } catch { startError = error }
        }, &objcError)
        if !started || startError != nil {
            input.removeTap(onBus: 0)
            throw startError ?? objcError ?? TBDSpeechError.microphoneUnavailable("engine failed")
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.queue.async { self?.scheduleRestart(after: 0.3) }
        }
        log.notice("mic_started sr=\(format.sampleRate, privacy: .public) ch=\(format.channelCount, privacy: .public)")
    }

    private func stopEngine() {
        restartGeneration += 1
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        _ = TBDCatchObjCException({
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }, nil)
        self.engine = nil
    }

    /// Route change (device plugged, default changed, sample rate changed): rebuild the engine.
    private func scheduleRestart(after delay: TimeInterval, attempt: Int = 0) {
        restartGeneration += 1
        let generation = restartGeneration
        queue.asyncAfter(deadline: .now() + delay) {
            guard generation == self.restartGeneration, !self.subscribers.isEmpty else { return }
            self.stopEngine()
            self.restartGeneration = generation
            do {
                try self.startEngine()
                self.log.notice("mic_restarted attempt=\(attempt, privacy: .public)")
            } catch where attempt < 3 {
                self.scheduleRestart(after: 0.5 * Double(attempt + 1), attempt: attempt + 1)
            } catch {
                let failed = self.subscribers.values.compactMap(\.onInterruption)
                self.subscribers.removeAll()
                self.refreshSnapshot()
                self.log.error("mic_restart_failed")
                for callback in failed { callback(error) }
            }
        }
    }
}
