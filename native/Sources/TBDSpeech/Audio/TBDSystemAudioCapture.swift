import AVFoundation
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Captures what the Mac plays (all apps except this process) through ScreenCaptureKit audio.
/// Needs the Screen & System Audio Recording permission. Delivers 16 kHz mono samples.
public final class TBDSystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias Handler = @Sendable ([Float]) -> Void
    private let queue = DispatchQueue(label: "com.tealbrick.desktop.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var handler: Handler?
    private var onStop: (@Sendable (Error) -> Void)?
    private let resampler = TBDMonoResampler()

    public override init() { super.init() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil }

    public func start(handler: @escaping Handler, onStop: (@Sendable (Error) -> Void)? = nil) async throws {
        guard !isRunning else { throw TBDSpeechError.busy("System audio capture") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw TBDSpeechError.audioUnreadable("no display is available for system audio capture")
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Video is required by the API; keep it tiny and slow.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        lock.withLock { self.handler = handler; self.onStop = onStop; self.stream = stream }
        do { try await stream.startCapture() } catch {
            lock.withLock { self.stream = nil; self.handler = nil }
            throw error
        }
    }

    public func stop() async {
        let stream = lock.withLock {
            defer { self.stream = nil; handler = nil; onStop = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        lock.lock(); let handler = self.handler; lock.unlock()
        guard let handler else { return }
        let samples = resampler.convert(buffer)
        if !samples.isEmpty { handler(samples) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let callback = onStop
        self.stream = nil; handler = nil; onStop = nil
        lock.unlock()
        callback?(error)
    }

    static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                   into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
