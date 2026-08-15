import Foundation
import Testing
@testable import VerbaliseCore

@Suite("Model folder completeness")
struct ModelFolderTests {

    static func makeFolder(items: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbalise-modelfolder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for item in items {
            if item.hasSuffix(".mlmodelc") {
                // The real thing is a directory; the check must accept that.
                try FileManager.default.createDirectory(
                    at: url.appendingPathComponent(item), withIntermediateDirectories: true
                )
            } else {
                try "x".write(
                    to: url.appendingPathComponent(item), atomically: true, encoding: .utf8
                )
            }
        }
        return url
    }

    @Test("A folder with every required item is complete")
    func completeFolder() throws {
        let folder = try Self.makeFolder(items: ModelFolder.requiredItems)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ModelFolder.isComplete(folder))
    }

    @Test("An interrupted download is not complete")
    func partialFolder() throws {
        // The exact folder a quit-mid-download left behind: encoder and mel
        // present, TextDecoder and config.json never arrived. Trusting it
        // wedged the app permanently — every load failed, and no download
        // restarted because the folder existed.
        let folder = try Self.makeFolder(items: [
            "MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!ModelFolder.isComplete(folder))
    }

    @Test("Optional extras are not required")
    func optionalFilesDoNotGate() throws {
        // TextDecoderContextPrefill and generation_config ship with the
        // models but WhisperKit loads without them; a folder must not be
        // held hostage to optional files.
        let folder = try Self.makeFolder(items: ModelFolder.requiredItems)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ModelFolder.isComplete(folder))
    }

    @Test("A missing folder is not complete")
    func missingFolder() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("verbalise-modelfolder-missing-\(UUID().uuidString)")
        #expect(!ModelFolder.isComplete(missing))
    }
}
