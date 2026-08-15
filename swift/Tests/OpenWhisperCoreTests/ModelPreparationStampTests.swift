import Foundation
import Testing
@testable import OpenWhisperCore

@Suite("First-use preparation stamps")
struct ModelPreparationStampTests {

    /// A throwaway defaults domain, so tests never read or write the real
    /// app's stamps.
    static func makeDefaults() throws -> UserDefaults {
        let name = "ow-stamp-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func makeModelFolder(files: [String: String] = ["model.bin": "weights"]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-stamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(
                to: url.appendingPathComponent(name), atomically: true, encoding: .utf8
            )
        }
        return url
    }

    @Test("Unstamped folder is not prepared; recording makes it prepared")
    func recordThenCheck() throws {
        let defaults = try Self.makeDefaults()
        let folder = try Self.makeModelFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: folder, defaults: defaults
        ))

        ModelPreparationStamp.recordPrepared(variant: "turbo", folder: folder, defaults: defaults)

        #expect(ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: folder, defaults: defaults
        ))
    }

    @Test("Rewritten files invalidate the stamp")
    func redownloadInvalidates() throws {
        // A re-download is what invalidates the ANE compile cache, so it is
        // the one thing the stamp absolutely must notice (#8: turbo was
        // re-downloaded, and its first load was presented as a few-second
        // one).
        let defaults = try Self.makeDefaults()
        let folder = try Self.makeModelFolder(files: ["model.bin": "weights"])
        defer { try? FileManager.default.removeItem(at: folder) }

        ModelPreparationStamp.recordPrepared(variant: "turbo", folder: folder, defaults: defaults)
        try "different weights".write(
            to: folder.appendingPathComponent("model.bin"), atomically: true, encoding: .utf8
        )

        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: folder, defaults: defaults
        ))
    }

    @Test("A touched file invalidates the stamp even at the same size")
    func mtimeChangeInvalidates() throws {
        let defaults = try Self.makeDefaults()
        let folder = try Self.makeModelFolder(files: ["model.bin": "weights"])
        defer { try? FileManager.default.removeItem(at: folder) }

        ModelPreparationStamp.recordPrepared(variant: "turbo", folder: folder, defaults: defaults)

        // Same byte count, different modification time -- what a re-download
        // of an unchanged file looks like.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 12345)],
            ofItemAtPath: folder.appendingPathComponent("model.bin").path
        )

        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: folder, defaults: defaults
        ))
    }

    @Test("Stamps are independent per variant")
    func variantsAreIndependent() throws {
        let defaults = try Self.makeDefaults()
        let folder = try Self.makeModelFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        ModelPreparationStamp.recordPrepared(variant: "small", folder: folder, defaults: defaults)

        #expect(ModelPreparationStamp.isPrepared(
            variant: "small", folder: folder, defaults: defaults
        ))
        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: folder, defaults: defaults
        ))
    }

    @Test("The fingerprint ignores where the folder lives")
    func fingerprintIsLocationIndependent() throws {
        // An app update moves the bundled model without touching its
        // contents; that must not read as a new model needing another
        // multi-minute compile.
        let original = try Self.makeModelFolder(files: ["a.bin": "aa", "b.bin": "bb"])
        defer { try? FileManager.default.removeItem(at: original) }
        let moved = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-stamp-moved-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: moved) }

        let before = ModelPreparationStamp.fingerprint(of: original)
        try FileManager.default.copyItem(at: original, to: moved)
        // A copy rewrites modification times; pin them back to the originals,
        // as an installer preserving file attributes would.
        for name in ["a.bin", "b.bin"] {
            let source = try FileManager.default.attributesOfItem(
                atPath: original.appendingPathComponent(name).path
            )
            try FileManager.default.setAttributes(
                [.modificationDate: source[.modificationDate] as Any],
                ofItemAtPath: moved.appendingPathComponent(name).path
            )
        }

        #expect(before != nil)
        #expect(ModelPreparationStamp.fingerprint(of: moved) == before)
    }

    @Test("A missing or empty folder has no fingerprint and is never prepared")
    func missingFolderFailsSafe() throws {
        let defaults = try Self.makeDefaults()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ow-stamp-missing-\(UUID().uuidString)")
        let empty = try Self.makeModelFolder(files: [:])
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(ModelPreparationStamp.fingerprint(of: empty) == nil)
        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: missing, defaults: defaults
        ))

        // Recording against an unreadable folder must store nothing rather
        // than a stamp that would match another unreadable folder later.
        ModelPreparationStamp.recordPrepared(variant: "turbo", folder: empty, defaults: defaults)
        #expect(!ModelPreparationStamp.isPrepared(
            variant: "turbo", folder: empty, defaults: defaults
        ))
    }
}
