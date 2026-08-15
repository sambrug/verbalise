import Foundation

/// What the Speech Model list shows for one tier.
///
/// Download and selection are deliberately independent. A user can fetch a
/// model they are not using yet -- so the switch, when they make it, is
/// instant rather than a multi-minute wait -- and can keep dictating with the
/// current model while a larger one downloads behind it. Collapsing the two
/// into "selecting downloads it" would make pre-fetching impossible and would
/// leave no way to cancel.
public enum ModelAvailability: Equatable, Sendable {
    /// On disk and the model dictation currently uses.
    case inUse
    /// On disk, not selected. One click away, no download.
    case ready
    /// Being fetched. `fraction` is nil until the total size is known.
    case downloading(fraction: Double?)
    /// On disk and being compiled for the Neural Engine — the one-off,
    /// minutes-long step after a download. For the selected model this is the
    /// wait dictation is gated behind; for any other it is a background step
    /// quietly making the tier instant to switch to. Shown either way, so the
    /// wait has a face and an explanation rather than looking like a model
    /// doing nothing.
    case compiling
    /// Not on disk and not being fetched.
    case absent
}

/// Everything the Speech Model pane needs for one row, derived rather than
/// stored so there is a single source of truth for a state that four separate
/// signals feed into.
public struct ModelRow: Equatable, Sendable {
    public let model: TranscriptionModel
    public let availability: ModelAvailability

    /// Whether there is a downloaded copy that could be deleted. False for the
    /// tier bundled inside the app, which is read-only and is what makes a
    /// fresh install work with no network.
    public let isRemovable: Bool

    public init(
        model: TranscriptionModel,
        availability: ModelAvailability,
        isRemovable: Bool = false
    ) {
        self.model = model
        self.availability = availability
        self.isRemovable = isRemovable
    }

    public var title: String { model.displayName }

    /// The second line: what the tier is for, which model that is, then its
    /// size or its progress.
    ///
    /// One line rather than three because all of it is the same decision --
    /// "most accurate, slowest", "Large v3" and "3.0 GB" are one trade-off
    /// described three ways, and splitting them makes the row taller for no
    /// gain. The model name sits in the middle deliberately: plain language
    /// first for the person choosing, the identifier next for the person
    /// checking.
    public var detail: String {
        switch availability {
        case .downloading(let fraction):
            return "\(model.summary) · \(model.variantName) · "
                + ModelCatalog.progressText(for: model, fraction: fraction)
        case .inUse, .ready, .compiling, .absent:
            return "\(model.summary) · \(model.variantName) · \(model.approximateDownloadSize)"
        }
    }

    /// Whether the row's trailing control is a button, and what it does.
    public var action: Action? {
        switch availability {
        case .inUse: nil                            // A badge, not a button.
        case .ready: isRemovable ? .remove : nil    // Selecting is a row tap.
        case .downloading: .cancel
        case .compiling: nil                        // A badge; nothing to cancel.
        case .absent: .download
        }
    }

    public enum Action: Equatable, Sendable {
        case download
        case cancel
        /// Only ever offered on a downloaded tier that is not in use, so it
        /// never has to unload a model mid-dictation.
        case remove

        public var title: String {
            switch self {
            case .download: "Download"
            case .cancel: "Cancel"
            case .remove: "Remove"
            }
        }

        /// Deleting gigabytes is worth marking as the destructive one.
        public var isDestructive: Bool { self == .remove }
    }

    /// Shown instead of a button when the model is the one in use.
    public var badge: String? {
        switch availability {
        case .inUse: "In use"
        case .compiling: "Compiling…"
        case .ready, .downloading, .absent: nil
        }
    }

    /// Whether the first-use compile is running, for the row's indeterminate
    /// bar. Always indeterminate: macOS gives no progress for the compile,
    /// and a bar pinned at zero for minutes reads as a hang — the very thing
    /// this row exists to dispel.
    public var isCompiling: Bool {
        availability == .compiling
    }

    /// 0...1 for the inline bar, or nil when there is no bar to draw.
    ///
    /// A download whose total size is not yet known reports nil, which the view
    /// renders as an indeterminate bar -- the alternative, a bar pinned at zero,
    /// reads as a stalled download rather than a starting one.
    public var progress: Double? {
        if case .downloading(let fraction) = availability { return fraction }
        return nil
    }

    public var isDownloading: Bool {
        if case .downloading = availability { return true }
        return false
    }
}

/// Derives the Speech Model list from the app's actual state.
///
/// Pure and separate from the view so the state table -- which is the part
/// with real edge cases, like a model selected while it is still downloading
/// -- can be tested without a window.
public enum ModelCatalog {

    /// One row per tier, in a fixed order.
    ///
    /// - Parameters:
    ///   - active: the model dictation uses right now. Usually the selected
    ///     model, but while a switch is staged — a new selection still
    ///     downloading or compiling — the old model stays active, keeps its
    ///     "In use" badge, and keeps transcribing. The selection checkmark is
    ///     the view's to draw; this list only ever reports what is true.
    ///   - downloaded: which models are on disk. The bundled tier is always in
    ///     this set in a real build, but not in a development build, so it is
    ///     passed in rather than assumed.
    ///   - downloading: in-flight downloads and their progress.
    ///   - removable: which models have a deletable downloaded copy. A subset
    ///     of `downloaded`: the bundled tier is present but not removable.
    ///   - compiling: models queued or running in the first-use Neural Engine
    ///     compile queue.
    public static func rows(
        active: TranscriptionModel,
        downloaded: Set<TranscriptionModel>,
        downloading: [TranscriptionModel: Double?] = [:],
        removable: Set<TranscriptionModel> = [],
        compiling: Set<TranscriptionModel> = []
    ) -> [ModelRow] {
        TranscriptionModel.allCases.map { model in
            ModelRow(
                model: model,
                availability: availability(
                    of: model,
                    active: active,
                    downloaded: downloaded,
                    downloading: downloading,
                    compiling: compiling
                ),
                isRemovable: removable.contains(model)
            )
        }
    }

    static func availability(
        of model: TranscriptionModel,
        active: TranscriptionModel,
        downloaded: Set<TranscriptionModel>,
        downloading: [TranscriptionModel: Double?],
        compiling: Set<TranscriptionModel> = []
    ) -> ModelAvailability {
        // Downloading wins over everything: whatever else is true of the
        // tier, the honest thing to show while bytes are moving is the
        // progress -- calling it anything grander when it cannot yet
        // transcribe is what makes a slow first dictation look like a hang.
        if let fraction = downloading[model] {
            return .downloading(fraction: fraction)
        }
        guard downloaded.contains(model) else { return .absent }
        // Compiling wins over "In use" for the same honesty: the badge would
        // claim a model that cannot yet transcribe anything.
        if compiling.contains(model) { return .compiling }
        return model == active ? .inUse : .ready
    }

    // MARK: - Sizes

    /// "1.9 of 3.0 GB downloaded", or "Downloading…" before the total is known.
    ///
    /// Both numbers use the unit the *total* calls for, so the pair reads as one
    /// measurement. Hand-rolled rather than `ByteCountFormatter` because that
    /// varies by locale and by macOS version, which would make this untestable
    /// for the sake of formatting two numbers.
    public static func progressText(
        for model: TranscriptionModel, fraction: Double?
    ) -> String {
        guard let fraction else { return "Downloading…" }
        let total = model.approximateDownloadBytes
        let done = Int64(Double(total) * max(0, min(1, fraction)))
        let unit = Unit.forTotal(total)
        return "\(unit.format(done, includeUnit: false)) of "
            + "\(unit.format(total, includeUnit: true)) downloaded"
    }

    /// A byte count on its own, e.g. "954 MB".
    public static func sizeText(_ bytes: Int64) -> String {
        Unit.forTotal(bytes).format(bytes, includeUnit: true)
    }

    /// Decimal units, matching how Apple reports storage and how the model
    /// filenames are named (`..._216MB` really is 216 × 10⁶).
    enum Unit {
        case megabytes
        case gigabytes

        static func forTotal(_ bytes: Int64) -> Unit {
            bytes >= 1_000_000_000 ? .gigabytes : .megabytes
        }

        func format(_ bytes: Int64, includeUnit: Bool) -> String {
            let text: String
            switch self {
            case .megabytes:
                // Sub-GB downloads move fast enough that a decimal place is
                // just a flickering digit.
                text = String(format: "%.0f", Double(bytes) / 1_000_000)
            case .gigabytes:
                text = String(format: "%.1f", Double(bytes) / 1_000_000_000)
            }
            guard includeUnit else { return text }
            return "\(text) \(self == .gigabytes ? "GB" : "MB")"
        }
    }
}
