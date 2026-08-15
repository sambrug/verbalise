import Foundation
import Testing

@testable import VerbaliseCore

/// The Speech Model pane's state table.
///
/// Worth testing apart from the window because four independent signals feed
/// one row -- active, on disk, downloading, progress known -- and the
/// combinations that matter are the ones a screenshot never shows you.
/// "Active" is the model dictation uses right now; while a switch is staged
/// it differs from the checkmarked selection, which is the view's concern.
@Suite("Model catalog")
struct ModelCatalogTests {

    @Test("One row per tier, in a stable order")
    func rowsCoverEveryTier() {
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [.balanced])
        #expect(rows.map(\.model) == TranscriptionModel.allCases)
    }

    @Test("The active model on disk is the one in use")
    func selectedAndPresentIsInUse() {
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [.balanced])
        let balanced = rows.first { $0.model == .balanced }
        #expect(balanced?.availability == .inUse)
        #expect(balanced?.badge == "In use")
        // A badge, not a button: there is nothing to do to a model already in
        // use, and offering an action implies otherwise.
        #expect(balanced?.action == nil)
    }

    @Test("A downloaded model that is not active is one click away")
    func downloadedButUnselectedIsReady() {
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [.balanced, .fast])
        let fast = rows.first { $0.model == .fast }
        #expect(fast?.availability == .ready)
        #expect(fast?.badge == nil)
        // Bundled, so nothing to reclaim: selecting the row is the whole
        // interaction.
        #expect(fast?.action == nil)
    }

    @Test("A downloaded model that is not in use can be removed")
    func downloadedAndUnselectedOffersRemove() {
        // Without this the accurate tier is three gigabytes that only deleting
        // the whole app reclaims.
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced, .accurate],
            removable: [.accurate]
        )
        let accurate = rows.first { $0.model == .accurate }
        #expect(accurate?.availability == .ready)
        #expect(accurate?.action == .remove)
        #expect(accurate?.action?.title == "Remove")
        #expect(accurate?.action?.isDestructive == true)
    }

    @Test("The model in use is never offered for removal")
    func inUseIsNotRemovable() {
        // Deleting the loaded model's files would leave the next dictation
        // with nothing to transcribe with.
        let rows = ModelCatalog.rows(
            active: .accurate,
            downloaded: [.accurate],
            removable: [.accurate]
        )
        #expect(rows.first { $0.model == .accurate }?.action == nil)
    }

    @Test("A bundled model offers no removal even though it is downloaded")
    func bundledIsNotRemovable() {
        // It lives in the app bundle, which is read-only under the sandbox and
        // is what makes a fresh install work offline.
        let rows = ModelCatalog.rows(
            active: .fast,
            downloaded: [.fast, .balanced],
            removable: []
        )
        #expect(rows.first { $0.model == .balanced }?.action == nil)
        #expect(rows.first { $0.model == .balanced }?.isRemovable == false)
    }

    @Test("A download in flight is never mistaken for something to remove")
    func downloadingIsNotRemovable() {
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced],
            downloading: [.accurate: 0.3],
            removable: [.accurate]
        )
        #expect(rows.first { $0.model == .accurate }?.action == .cancel)
    }

    @Test("A model that is not on disk offers a download")
    func absentOffersDownload() {
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [.balanced])
        let accurate = rows.first { $0.model == .accurate }
        #expect(accurate?.availability == .absent)
        #expect(accurate?.action == .download)
        #expect(accurate?.action?.title == "Download")
        #expect(accurate?.progress == nil)
    }

    @Test("A download in flight offers a cancel and a progress bar")
    func downloadingOffersCancel() {
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced],
            downloading: [.accurate: 0.62]
        )
        let accurate = rows.first { $0.model == .accurate }
        #expect(accurate?.availability == .downloading(fraction: 0.62))
        #expect(accurate?.action == .cancel)
        #expect(accurate?.progress == 0.62)
        #expect(accurate?.isDownloading == true)
    }

    @Test("Downloading another tier does not disturb the one in use")
    func downloadingDoesNotStealInUse() {
        // The whole point of separating download from selection: dictation must
        // keep working with the current model while a larger one is fetched.
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced],
            downloading: [.accurate: 0.62]
        )
        #expect(rows.first { $0.model == .balanced }?.availability == .inUse)
    }

    @Test("The active model mid-download reads as downloading, not in use")
    func selectedWhileDownloadingIsNotInUse() {
        // Calling it "In use" while it cannot transcribe anything is exactly
        // what makes the first dictation after a switch look like a hang.
        let rows = ModelCatalog.rows(
            active: .accurate,
            downloaded: [.balanced],
            downloading: [.accurate: 0.1]
        )
        let accurate = rows.first { $0.model == .accurate }
        #expect(accurate?.availability == .downloading(fraction: 0.1))
        #expect(accurate?.badge == nil)
    }

    @Test("A model mid first-use compile reads as compiling, not in use")
    func compilingIsNotInUse() {
        // Same honesty as the downloading case: "In use" on a model that
        // cannot yet transcribe anything is what makes the multi-minute
        // Neural Engine compile look like a hang.
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced],
            compiling: [.balanced]
        )
        let balanced = rows.first { $0.model == .balanced }
        #expect(balanced?.availability == .compiling)
        #expect(balanced?.badge == "Compiling…")
        #expect(balanced?.action == nil)
        #expect(balanced?.isCompiling == true)
        #expect(balanced?.progress == nil, "the compile has no measurable progress")
    }

    @Test("The compile only marks the models actually compiling")
    func compilingDoesNotSpread() {
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced, .fast],
            compiling: [.balanced]
        )
        #expect(rows.first { $0.model == .fast }?.availability == .ready)
        #expect(rows.first { $0.model == .fast }?.isCompiling == false)
    }

    @Test("A staged switch keeps the old model in use while the new one compiles")
    func backgroundCompileShows() {
        // The staged-switch contract: selecting a tier that still needs its
        // download or compile keeps dictation on the current model, so the
        // pane must show the old tier as in use and the new one as working —
        // never a "Ready" it cannot yet honour.
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced, .accurate],
            compiling: [.accurate]
        )
        #expect(rows.first { $0.model == .balanced }?.availability == .inUse)
        #expect(rows.first { $0.model == .accurate }?.availability == .compiling)
    }

    @Test("A download whose size is not yet known still reads as a download")
    func unknownProgressIsStillDownloading() {
        let rows = ModelCatalog.rows(
            active: .balanced,
            downloaded: [.balanced],
            downloading: [.fast: Double?.none]
        )
        let fast = rows.first { $0.model == .fast }
        #expect(fast?.isDownloading == true)
        #expect(fast?.progress == nil)   // Indeterminate bar, not a bar at zero.
        #expect(fast?.action == .cancel)
        #expect(fast?.detail.hasSuffix("Downloading…") == true)
    }

    @Test("A development build with nothing on disk offers all three")
    func nothingDownloadedOffersEverything() {
        // The bundled tier is only bundled in a release build; a dev build
        // starts empty and must not claim otherwise.
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [])
        #expect(rows.allSatisfy { $0.availability == .absent })
        #expect(rows.allSatisfy { $0.action == .download })
    }

    // MARK: - Copy

    @Test("Every tier's detail names the trade and the size")
    func detailPairsSummaryWithSize() {
        let rows = ModelCatalog.rows(active: .balanced, downloaded: [.balanced])
        #expect(rows[0].detail == "Quickest, least accurate · Whisper Small · 216 MB")
        #expect(
            rows[1].detail
                == "Balance of speed and accuracy · Whisper Large v3 Turbo · 954 MB"
        )
        #expect(rows[2].detail == "Most accurate, slowest · Whisper Large v3 · 3.0 GB")
    }

    @Test("Every tier names its underlying model in full")
    func variantNamesAreDistinct() {
        let names = TranscriptionModel.allCases.map(\.variantName)
        #expect(Set(names).count == names.count)
        // Named in full rather than abbreviated: "Small" on its own says
        // nothing to someone who does not already know what is under the app.
        #expect(names.allSatisfy { $0.hasPrefix("Whisper ") })
    }

    @Test("The three summaries are parallel, not one-off descriptions")
    func summariesAreParallel() {
        // They are read against each other, so they must be comparable: same
        // shape, no trailing sentence, and none of them describing packaging
        // instead of performance.
        for model in TranscriptionModel.allCases {
            #expect(!model.summary.hasSuffix("."))
            #expect(!model.summary.contains("Included"))
            #expect(model.summary.first?.isUppercase == true)
        }
    }

    @Test("Progress reads as one measurement in the total's unit")
    func progressTextUsesOneUnit() {
        #expect(
            ModelCatalog.progressText(for: .accurate, fraction: 0.633)
                == "1.9 of 3.0 GB downloaded"
        )
        #expect(
            ModelCatalog.progressText(for: .fast, fraction: 0.5)
                == "108 of 216 MB downloaded"
        )
    }

    @Test("Progress with no known total says so rather than showing zero")
    func progressTextWithoutFraction() {
        #expect(ModelCatalog.progressText(for: .accurate, fraction: nil) == "Downloading…")
    }

    @Test("Progress outside 0...1 is clamped")
    func progressTextClamps() {
        // WhisperKit's Progress has reported fractions slightly over 1 on
        // completion; "3.1 of 3.0 GB" would be a visible embarrassment.
        #expect(ModelCatalog.progressText(for: .accurate, fraction: 1.4)
            == "3.0 of 3.0 GB downloaded")
        #expect(ModelCatalog.progressText(for: .accurate, fraction: -2)
            == "0.0 of 3.0 GB downloaded")
    }

    @Test("Sizes pick their unit from the magnitude")
    func sizeTextPicksUnit() {
        #expect(ModelCatalog.sizeText(216_000_000) == "216 MB")
        #expect(ModelCatalog.sizeText(954_000_000) == "954 MB")
        #expect(ModelCatalog.sizeText(3_000_000_000) == "3.0 GB")
        #expect(ModelCatalog.sizeText(1_000_000_000) == "1.0 GB")
        #expect(ModelCatalog.sizeText(999_000_000) == "999 MB")
    }
}
