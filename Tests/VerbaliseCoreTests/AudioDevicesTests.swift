import Testing
@testable import VerbaliseCore

/// Exercises the CoreAudio enumeration against the real system.
///
/// Deliberately tolerant: a machine with no input device is unusual but legal
/// (a headless CI box), and these must not fail there. What they do catch is
/// the enumeration being *wrong* -- garbage names, duplicate IDs, a default
/// that is not in the list -- which type-checking cannot.
///
/// Listing devices needs no microphone permission; only opening one does. So
/// this runs without a TCC grant, which a test binary would not have.
@Suite("Audio device enumeration")
struct AudioDevicesTests {

    @Test("Input devices have usable names and unique IDs")
    func inputDevicesAreWellFormed() {
        let devices = AudioDevices.inputDevices()

        for device in devices {
            #expect(!device.name.isEmpty, "a device reported an empty name")
            #expect(device.name.trimmingCharacters(in: .whitespaces) == device.name
                    || !device.name.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(device.id != 0, "0 is not a valid device ID")
        }

        let ids = Set(devices.map(\.id))
        #expect(ids.count == devices.count, "device IDs must be unique")
    }

    @Test("The default input, when present, is among the listed inputs")
    func defaultInputIsListed() {
        guard let device = AudioDevices.defaultInputDevice() else { return }

        let listed = AudioDevices.inputDevices()
        #expect(
            listed.contains { $0.id == device.id },
            "default input \(device.name) missing from \(listed.map(\.name))"
        )
    }

    @Test("Enumeration is stable across repeated calls")
    func enumerationIsStable() {
        // A leak or a mis-sized buffer in the CoreAudio calls tends to show up
        // as results that change between identical calls.
        let first = AudioDevices.inputDevices()
        let second = AudioDevices.inputDevices()
        #expect(first == second)
    }
}
