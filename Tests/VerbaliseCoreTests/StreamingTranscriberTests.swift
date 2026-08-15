import Foundation
import Testing
@testable import VerbaliseCore

/// Scenario group 10 from tests/test_recovery.py.
@Suite("Streaming transcription")
struct StreamingTranscriberTests {

    static let chunk = [Float](repeating: 0, count: 16_000)

    @Test("chunks join in feed order, not completion order")
    func chunksJoinInFeedOrder() async {
        // The first chunk deliberately finishes last. Ordering by completion
        // would silently scramble the user's sentences.
        let streamer = StreamingTranscriber(transcriber: OutOfOrderTranscriber())
        await streamer.feed(Self.chunk)
        await streamer.feed(Self.chunk)

        #expect(await streamer.drain() == ["one", "two"])
        #expect(await streamer.failed == false)
    }

    @Test("a failed chunk is flagged rather than crashing the streamer")
    func failedChunkIsFlagged() async {
        let streamer = StreamingTranscriber(transcriber: FailingTranscriber())
        await streamer.feed(Self.chunk)

        #expect(await streamer.drain() == [""])
        #expect(await streamer.failed)
    }

    @Test("one failure among several still yields a slot per chunk")
    func failureKeepsSlotCount() async {
        // drain() must return one entry per fed chunk so the caller can tell
        // which position went missing, rather than silently returning fewer.
        let streamer = StreamingTranscriber(transcriber: FailingTranscriber())
        for _ in 0..<3 { await streamer.feed(Self.chunk) }

        let results = await streamer.drain()
        #expect(results.count == 3)
        #expect(await streamer.failed)
    }

    @Test("chunk count tracks every fed chunk")
    func chunkCountTracksFeeds() async {
        let streamer = StreamingTranscriber(transcriber: FixedTranscriber())
        #expect(await streamer.chunkCount == 0)

        for _ in 0..<4 { await streamer.feed(Self.chunk) }
        #expect(await streamer.chunkCount == 4)

        _ = await streamer.drain()
        #expect(await streamer.chunkCount == 4, "draining must not reset the count")
    }

    @Test("draining with nothing fed yields nothing")
    func drainWithNoChunks() async {
        let streamer = StreamingTranscriber(transcriber: FixedTranscriber())
        #expect(await streamer.drain().isEmpty)
        #expect(await streamer.failed == false)
    }

    @Test("feed indices are sequential")
    func feedIndicesAreSequential() async {
        let streamer = StreamingTranscriber(transcriber: FixedTranscriber())
        let first = await streamer.feed(Self.chunk)
        let second = await streamer.feed(Self.chunk)
        let third = await streamer.feed(Self.chunk)

        let indices: [Int] = [first, second, third]
        #expect(indices == [0, 1, 2])
        _ = await streamer.drain()
    }
}

/// The chunk-joining punctuation rules the plan calls out in §6 scenario 10.
/// The pure function is already covered differentially against Python in
/// FixtureTests; these name the rules explicitly, in the Python suite's terms.
@Suite("Chunk joining rules")
struct ChunkJoiningRuleTests {

    @Test("spurious boundary period dropped before a lowercase continuation")
    func boundaryPeriodDropped() {
        #expect(
            TextPipeline.joinStreamingChunks(["still talking.", "and continuing on"])
                == "still talking and continuing on"
        )
    }

    @Test("real sentence end kept before a capital")
    func realSentenceEndKept() {
        #expect(
            TextPipeline.joinStreamingChunks(["First sentence.", "Second one starts here."])
                == "First sentence. Second one starts here."
        )
    }

    @Test("no punctuation at the boundary is untouched")
    func noPunctuationUntouched() {
        #expect(
            TextPipeline.joinStreamingChunks(["one two", "three four"]) == "one two three four"
        )
    }

    @Test("empty and blank chunks are skipped")
    func blankChunksSkipped() {
        #expect(
            TextPipeline.joinStreamingChunks(["", "  ", "hello", "", "world"]) == "hello world"
        )
    }

    @Test("a single chunk passes through unchanged")
    func singleChunkPassesThrough() {
        #expect(TextPipeline.joinStreamingChunks(["just one chunk."]) == "just one chunk.")
    }

    @Test("nothing but empty chunks joins to an empty string")
    func allEmptyJoinsToEmpty() {
        #expect(TextPipeline.joinStreamingChunks(["", "  "]) == "")
    }
}
