import Foundation
import Testing
@testable import VerbaliseCore

/// Scenario group 11 from tests/test_recovery.py.
@Suite("Idle model unload")
struct ModelLifecycleTests {

    @Test("not before the threshold")
    func notBeforeThreshold() async {
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 30 * 60)

        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false) == false)
        #expect(unloads.value == 0)
        #expect(await lifecycle.isLoaded)
    }

    @Test("fires past the threshold")
    func firesPastThreshold() async {
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 121 * 60)

        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false))
        #expect(unloads.value == 1)
        #expect(await lifecycle.isLoaded == false)
    }

    @Test("never unloads during a recording")
    func neverDuringRecording() async {
        // Unloading mid-dictation would strand the recording.
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 500 * 60)

        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: true) == false)
        #expect(unloads.value == 0)
        #expect(await lifecycle.isLoaded)
    }

    @Test("0 disables unloading entirely")
    func zeroDisables() async {
        // Documented as "keeps it loaded forever".
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 10_000 * 60)

        #expect(await lifecycle.maybeUnload(idleMinutes: 0, isRecording: false) == false)
        #expect(unloads.value == 0)
    }

    @Test("an already-unloaded model does not unload twice")
    func doesNotUnloadTwice() async {
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 200 * 60)
        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false))

        clock.advance(by: 200 * 60)
        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false) == false)
        #expect(unloads.value == 1)
    }

    @Test("activity resets the idle timer")
    func activityResetsTimer() async {
        let clock = TestClock()
        let unloads = Counter()
        let lifecycle = ModelLifecycle(clock: clock) { unloads.increment() }
        await lifecycle.noteLoaded()

        clock.advance(by: 119 * 60)
        await lifecycle.noteActivity()
        clock.advance(by: 119 * 60)

        // Without the reset this would be 238 minutes idle and would unload.
        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false) == false)
        #expect(unloads.value == 0)
    }

    @Test("reloading resets the idle timer")
    func reloadResetsTimer() async {
        let clock = TestClock()
        let lifecycle = ModelLifecycle(clock: clock)
        await lifecycle.noteLoaded()

        clock.advance(by: 200 * 60)
        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false))

        await lifecycle.noteLoaded()
        #expect(await lifecycle.isLoaded)
        #expect(await lifecycle.maybeUnload(idleMinutes: 120, isRecording: false) == false)
    }
}
