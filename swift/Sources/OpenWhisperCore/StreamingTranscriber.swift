import Foundation

/// Transcribes chunks as they are fed in, so a long dictation is mostly
/// transcribed by the time the key is released (daemon.py:446).
///
/// Chunks are cut at natural pauses while the user is still speaking, which
/// keeps the wait after key release short regardless of how long they talked.
public actor StreamingTranscriber {

    private let transcriber: any Transcriber
    private var results: [Int: String] = [:]
    private var inFlight: [Task<Void, Never>] = []
    private var nextIndex = 0

    /// True when any chunk failed. The caller falls back to transcribing the
    /// whole clip in one pass rather than shipping a transcript with a hole in
    /// the middle -- a silently missing sentence is worse than a slow one.
    public private(set) var failed = false

    public private(set) var chunkCount = 0

    public init(transcriber: any Transcriber) {
        self.transcriber = transcriber
    }

    /// Enqueues a chunk and returns its index.
    ///
    /// The index, not completion order, determines where the chunk lands in the
    /// final transcript. Chunks are transcribed concurrently and a short later
    /// chunk routinely finishes before a long earlier one; ordering by
    /// completion would silently scramble the user's sentences.
    @discardableResult
    public func feed(_ audio: [Float]) -> Int {
        let index = nextIndex
        nextIndex += 1
        chunkCount += 1

        let task = Task { [transcriber] in
            do {
                let text = try await transcriber.transcribe(audio)
                await self.store(text, at: index)
            } catch {
                log("streaming: chunk \(index) transcribe failed — \(error)")
                await self.markFailed(at: index)
            }
        }
        inFlight.append(task)
        return index
    }

    /// Waits for every fed chunk and returns their transcripts in feed order.
    public func drain() async -> [String] {
        let pending = inFlight
        inFlight.removeAll()
        for task in pending {
            await task.value
        }
        return results.keys.sorted().map { results[$0] ?? "" }
    }

    private func store(_ text: String, at index: Int) {
        results[index] = text
    }

    private func markFailed(at index: Int) {
        // Record an empty result so the index still exists and drain() returns
        // a slot per fed chunk, matching the Python.
        results[index] = ""
        failed = true
    }
}
