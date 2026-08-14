import AVFoundation
import CoreAudio
import Foundation

/// The real `AudioStream`, over `AVAudioEngine` (replacing the Python's
/// `sounddevice` usage).
///
/// Whisper wants 16 kHz mono Float32, and the hardware almost never provides
/// that directly -- built-in mics typically run 44.1 or 48 kHz, and often with
/// more than one channel -- so every buffer goes through an `AVAudioConverter`.
///
/// The protocol's methods are synchronous and allowed to block, which is
/// honest here rather than convenient: `AVAudioEngine.stop()` genuinely can
/// block forever when CoreAudio has stopped running the IO proc, and that is
/// precisely the failure `AudioSession` bounds with a timeout. Wrapping these
/// in `async` would hide the hazard the whole recovery design exists for.
public final class AVAudioCaptureStream: AudioStream, @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double
    private let deviceID: AudioDeviceID?
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: @Sendable (Float) -> Void

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var tapInstalled = false

    public init(
        targetSampleRate: Double,
        deviceID: AudioDeviceID? = nil,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
    ) {
        self.targetSampleRate = targetSampleRate
        self.deviceID = deviceID
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    public func start() throws {
        let input = engine.inputNode

        // Device selection must happen before the engine is prepared: the HAL
        // unit binds to a device at that point and will not switch afterwards.
        if let deviceID {
            try setInputDevice(deviceID, on: input)
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputFormat
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.unsupportedFormat
        }

        let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat)
        lock.withLock { self.converter = converter }

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handle(buffer, targetFormat: targetFormat)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    /// Stop without waiting to drain. The one call with a chance of returning
    /// when the IO proc is already gone.
    public func abort() {
        engine.stop()
    }

    public func stop() {
        engine.stop()
    }

    public func close() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        lock.withLock { converter = nil }
    }

    // MARK: - Tap

    /// Runs on a realtime audio thread. It must not allocate unpredictably,
    /// block, or take a contended lock for long -- overrunning here causes
    /// glitches and dropouts, not just slowness.
    private func handle(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter = lock.withLock({ self.converter }) else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            // The converter asks repeatedly; feeding the same buffer twice
            // would duplicate audio, so the second ask reports starvation.
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        onSamples(samples)

        // Level for the pill's bars. RMS rather than peak: peak jitters too
        // much to read as a level meter.
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        onLevel((sum / Float(samples.count)).squareRoot())
    }

    private func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) throws {
        var id = deviceID
        let status = AudioUnitSetProperty(
            node.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.deviceSelectionFailed(status)
        }
    }
}

public enum AudioCaptureError: Error, LocalizedError {
    case noInputFormat
    case unsupportedFormat
    case deviceSelectionFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noInputFormat: "The input device reported no usable format."
        case .unsupportedFormat: "Could not build a 16 kHz mono format."
        case .deviceSelectionFailed(let status): "Could not select the input device (\(status))."
        }
    }
}

/// Opens `AVAudioCaptureStream`s, resolving the configured device name each
/// time so a device that appears or disappears between dictations is picked up
/// without a restart.
public struct AVAudioCaptureOpener: AudioStreamOpening {

    private let sampleRate: Double
    private let deviceName: String?
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevel: @Sendable (Float) -> Void

    public init(
        sampleRate: Double,
        deviceName: String?,
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void = { _ in }
    ) {
        self.sampleRate = sampleRate
        self.deviceName = deviceName
        self.onSamples = onSamples
        self.onLevel = onLevel
    }

    public func open() throws -> any AudioStream {
        // An unmatched name falls back to the system default rather than
        // failing: a user who unplugs the interface named in their config
        // should still be able to dictate.
        var resolved: AudioDeviceID?
        if let deviceName {
            resolved = AudioDevices.inputDevices().first { $0.name == deviceName }?.id
            if resolved == nil {
                log("audio: input device '\(deviceName)' not found, using the system default")
            }
        }

        let stream = AVAudioCaptureStream(
            targetSampleRate: sampleRate,
            deviceID: resolved,
            onSamples: onSamples,
            onLevel: onLevel
        )
        try stream.start()
        return stream
    }
}
