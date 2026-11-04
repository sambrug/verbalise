import Foundation
import Testing
@testable import VerbaliseCore

@Suite("Performance diagnostics")
struct DiagnosticsTests {
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) { lock.withLock { storage.append(line) } }
        var values: [String] { lock.withLock { storage } }
    }

    struct ObservedTranscriber: Transcriber {
        func transcribe(_ audio: [Float]) async throws -> String {
            await Task.yield()
            log("test: transcription")
            return "PRIVATE DICTATION CONTENT"
        }
    }

    @Test("Concurrent recordings retain separate IDs and never log transcript text")
    func concurrentContexts() async {
        let lines = Lines()
        await Diagnostics.$sink.withValue({ lines.append($0) }) {
            await withTaskGroup(of: Void.self) { group in
                for id in ["recording-a", "recording-b"] {
                    group.addTask {
                        let stream = StreamingTranscriber(transcriber: ObservedTranscriber(),
                            context: .init(dictation: id))
                        await stream.feed([0.1, 0.2])
                        await stream.feed([0.3], reason: "tail")
                        _ = await stream.drain()
                    }
                }
            }
        }
        let calls = lines.values.filter { $0.contains("test: transcription") }
        #expect(calls.count == 4)
        for id in ["recording-a", "recording-b"] {
            for chunk in 0...1 {
                #expect(calls.filter { $0.contains("dictation=\(id) chunk=\(chunk)") }.count == 1)
            }
        }
        #expect(!lines.values.contains { $0.contains("PRIVATE DICTATION CONTENT") })
    }

    @Test("Stop-to-handoff includes dispatch, recognition and paste delays")
    func handoffTiming() async {
        let lines = Lines()
        let clock = TestClock()
        let keyboard = FakeKeyboard()
        let clipboard = FakeClipboard()
        let secret = "PRIVATE DICTATION CONTENT"
        var settings = Settings()
        settings.advanced.fastTypingEnabled = false
        settings.advanced.clipboardRestoreDelay = 0
        settings.releaseDelay = 0.05
        let transcriber = DictationControllerTests.HookedTranscriber(text: secret) {
            clock.advance(by: 2)
        }
        let controller = DictationController(
            session: AudioSession(opener: HealthyOpener()), transcriber: transcriber,
            inserter: TextInserter(keyboard: keyboard, pasteboard: clipboard, clock: clock),
            settings: settings, clock: clock)
        await Diagnostics.$sink.withValue({ lines.append($0) }) {
            await controller._prepareForTest(stream: HealthyStream(), audio: [Float](repeating: 0.1, count: 32000))
            let releasedAt = clock.now - 0.25
            await controller.stopAndTranscribe(requestedAt: releasedAt)
        }
        let handoff = lines.values.first { $0.contains("insertion: path=pasted") } ?? ""
        let token = handoff.split(separator: " ").first { $0.hasPrefix("stop_to_handoff_s=") }
        let elapsed = token.flatMap { Double($0.dropFirst("stop_to_handoff_s=".count)) } ?? -1
        #expect(abs(elapsed - 2.30) < 0.001)
        #expect(lines.values.contains { $0.contains("dispatch_s=0.25") })
        #expect(lines.values.contains { $0.contains("end outcome=pasted") })
        #expect(!lines.values.contains { $0.contains(secret) })
        #expect(clipboard.read() == secret)
    }

    @Test("Blocking audio threads preserve correlation")
    func boundedContext() async {
        let lines = Lines()
        await Diagnostics.$sink.withValue({ lines.append($0) }) {
            await Diagnostics.$context.withValue(.init(dictation: "audio-test")) {
                _ = await Bounded.run(timeout: .seconds(1)) { log("test: audio_thread"); return true }
            }
        }
        #expect(lines.values == ["[dictation=audio-test chunk=session] test: audio_thread"])
    }

    @Test("Rotation retains recent archives in order and leaves small files alone")
    func rotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("verbalise.log")
        for number in 1...5 {
            try Data("entry-\(number)".utf8).write(to: file)
            Log.rotateIfNeeded(file, incomingBytes: 5, limit: 10, archives: 3)
        }
        #expect(try String(contentsOf: file.appendingPathExtension("1"), encoding: .utf8) == "entry-5")
        #expect(try String(contentsOf: file.appendingPathExtension("3"), encoding: .utf8) == "entry-3")
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("4").path))
        try Data("small".utf8).write(to: file)
        Log.rotateIfNeeded(file, incomingBytes: 1, limit: 10)
        #expect(try String(contentsOf: file, encoding: .utf8) == "small")
    }
}
