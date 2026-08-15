import AVFoundation
import CoreAudio
import Foundation

/// CoreAudio input-device enumeration for the Input Device picker
/// (legacy-python/menubar.py:633).
public enum AudioDevices {

    public struct Device: Identifiable, Sendable, Equatable {
        public let id: AudioDeviceID
        public let name: String
    }

    /// Every device that can actually record, in CoreAudio's order.
    ///
    /// Filtered on having input streams rather than on name or transport type:
    /// plenty of devices are output-only, and an aggregate or virtual device is
    /// a perfectly valid input that a name-based heuristic would miss.
    public static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap { id in
            guard hasInputStreams(id), let name = name(of: id) else { return nil }
            return Device(id: id, name: name)
        }
    }

    /// The system default input, used when `input_device` is unset.
    public static func defaultInputDevice() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0, let name = name(of: deviceID) else { return nil }
        return Device(id: deviceID, name: name)
    }

    // MARK: - Internals

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }

        let result = name as String
        return result.isEmpty ? nil : result
    }
}

/// Opens and immediately closes a throwaway stream at startup (legacy-python/daemon.py:958).
///
/// The first CoreAudio activation in a process is slow -- the HAL loads
/// drivers and negotiates formats -- and without this that cost lands on the
/// user's first keypress, making the app feel like it missed the trigger.
/// Paying it at launch, when nobody is waiting, makes the first dictation feel
/// the same as every later one.
public enum AudioPrewarm {
    public static func run(sampleRate: Double = 16_000) {
        let stream = AVAudioCaptureStream(
            targetSampleRate: sampleRate,
            deviceID: nil,
            onSamples: { _ in },
            onLevel: { _ in }
        )
        do {
            try stream.start()
            stream.close()
            log("audio: pre-warmed")
        } catch {
            // Never fatal. A failure here means the first real dictation pays
            // the activation cost, not that anything is broken.
            log("audio: pre-warm failed — \(error)")
        }
    }
}
