import Testing
@testable import VerbaliseCore

@Suite("Unicode typing chunker")
struct KeyboardChunkingTests {

    @Test("Short text is a single chunk")
    func shortTextOneChunk() {
        #expect(SystemKeyboard.chunks(of: "hello") == ["hello"])
    }

    @Test("Empty text produces no chunks")
    func emptyTextNoChunks() {
        #expect(SystemKeyboard.chunks(of: "").isEmpty)
    }

    @Test("Long text splits into 20-unit chunks that rejoin exactly")
    func longTextSplitsAndRejoins() {
        let text = String(repeating: "abcde", count: 20) // 100 chars
        let chunks = SystemKeyboard.chunks(of: text)

        #expect(chunks.count == 5)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        // The only property that actually matters: nothing is lost or reordered.
        #expect(chunks.joined() == text)
    }

    @Test("Surrogate pairs are never split")
    func surrogatePairsIntact() {
        // Emoji are 2 UTF-16 units each. Chunking the UTF-16 array directly
        // would cut one in half at the boundary and emit replacement
        // characters; chunking on Character boundaries cannot.
        let text = String(repeating: "😀", count: 15) // 30 UTF-16 units
        let chunks = SystemKeyboard.chunks(of: text)

        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
        for chunk in chunks {
            #expect(!chunk.unicodeScalars.contains { $0.value == 0xFFFD })
            // Whole emoji only.
            #expect(chunk.utf16.count % 2 == 0)
        }
    }

    @Test("A single character wider than the chunk budget still emits")
    func oversizedGraphemeStillEmitted() {
        // One base letter plus a stack of combining accents is a single
        // Character that cannot fit the 20-unit budget. It must still be typed
        // whole rather than dropped or split -- splitting would detach the
        // accents from their base and change the text.
        let oversized = "a" + String(repeating: "\u{0301}", count: 30)
        #expect(oversized.count == 1)
        #expect(oversized.utf16.count > 20)
        #expect(SystemKeyboard.chunks(of: oversized) == [oversized])
    }

    @Test("Mixed ASCII and emoji rejoins exactly")
    func mixedContentRejoins() {
        let text = "Ship it 🚀 today, then review 📝 the diff and merge 🎉 it."
        #expect(SystemKeyboard.chunks(of: text).joined() == text)
    }
}
