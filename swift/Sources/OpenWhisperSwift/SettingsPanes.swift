import OpenWhisperCore
import SwiftUI

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: paneSelection) { pane in
                PaneLabel(
                    pane: pane,
                    needsAttention: pane == .permissions && model.permissionsNeedAttention
                )
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(200)
            // No sidebar toggle. NavigationSplitView adds one to the toolbar
            // by default, and it sits at the sidebar's trailing edge -- so
            // clicking it collapses the sidebar and the button jumps across
            // the window to follow it. There is nothing to gain from hiding
            // the sidebar in a settings window (System Settings does not offer
            // it either), and a control whose first act is to move away from
            // the pointer is worse than no control.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// `List` wants an optional selection; the window always has a pane open, so
    /// a nil write (which a click on empty sidebar space produces) is ignored
    /// rather than allowed to blank the detail column.
    private var paneSelection: Binding<SettingsPane?> {
        Binding(
            get: { model.selection },
            set: { if let new = $0 { model.selection = new } }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .general: GeneralPane(model: model)
        case .dictation: DictationPane(model: model)
        case .speechModel: SpeechModelPane(model: model)
        case .vocabulary: VocabularyPane(model: model)
        case .permissions: PermissionsPane(model: model)
        }
    }
}

/// A sidebar row: tinted rounded square, name, and an attention dot.
private struct PaneLabel: View {
    let pane: SettingsPane
    let needsAttention: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pane.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
            Text(pane.title)
            if needsAttention {
                Spacer(minLength: 4)
                // The same dot System Settings uses for an unfinished setup:
                // the pane that needs you is findable without opening all seven.
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Needs attention")
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    /// Nil until there is a meaningful amount of it, which is what both the
    /// row and its footnote key off.
    private var timeSaved: String? { StatsFormatter.timeSaved(model.stats) }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                )) {
                    // No subtitle: the label says the whole thing, and the one
                    // that was here described the app rather than the switch.
                    // System Settings' own Login Items rows carry no
                    // explanation either.
                    Text("Open at login")
                }

                Toggle(isOn: model.binding(\.overlayStyle, as: { $0 == .on }, to: { $0 ? .on : .off })) {
                    Text("Show recording overlay")
                    Text("Shows the microphone level while you speak.")
                }

                Toggle(isOn: model.binding(\.soundEnabled)) {
                    Text("Play sounds")
                    Text("A short tone when recording starts and stops.")
                }
            }

            Section {
                LabeledContent("Dictations",
                               value: StatsFormatter.grouped(model.stats.totalRecordings))
                LabeledContent("Words",
                               value: StatsFormatter.grouped(model.stats.totalWords))
                // Only once there is enough to be worth saying. "0 minutes" on
                // a fresh install is a worse greeting than no row at all.
                if let saved = timeSaved {
                    LabeledContent("Time saved typing", value: saved)
                }
            } header: {
                Text("Usage")
            } footer: {
                // Tied to the row it explains. Shown on its own it described
                // an arithmetic nobody could see the result of, under two
                // rows that are plain counts and need no explaining.
                if timeSaved != nil {
                    Text("Based on typing at 40 words a minute and speaking at 150.")
                        .settingsFootnote()
                }
            }

            Section {
                Button("Open Configuration File") { model.openConfigFile() }
                Button("Show Log") { model.showLog() }
                // Last, because it is the only one that interrupts anything.
                // Its reason for existing is the audio system wedging, which
                // the menu bar warns about and links here.
                Button("Restart Open Whisper") { model.restart() }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Restarting can resolve problems with dictation.")
                    .settingsFootnote()
            }
        }
        .paneStyle()
    }
}

// MARK: - Dictation

/// Trigger, microphone and output in one place.
///
/// These were three panes with four controls between them. Beyond the empty
/// rooms, splitting them hid the fact that the trigger key and the microphone
/// are the two things a new user actually has to get right.
private struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Hold to dictate", selection: Binding(
                    get: { model.settings.triggerKey },
                    set: { new in model.change { $0.triggerKey = new } }
                )) {
                    ForEach(triggerOptions, id: \.configValue) { combo in
                        Text(combo.displayName).tag(combo.configValue)
                    }
                }
            } header: {
                Text("Trigger Key")
            } footer: {
                Text("Hold while you speak, then release. "
                     + "Press Escape to stop without inserting anything.")
                .settingsFootnote()
            }

            Section {
                Picker("Microphone", selection: deviceSelection) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(model.inputDevices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }

                LabeledContent("Input level") {
                    if model.inputPreviewFailed {
                        // A flat meter and an unavailable microphone look
                        // identical, and only one of them is the user's
                        // problem to solve.
                        Text("Microphone unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        InputLevelMeter(
                            meter: model.inputPreviewMeter,
                            isRunning: model.isPreviewingInput
                        )
                    }
                }

                Toggle(isOn: model.binding(\.advanced.trimSilenceEnabled)) {
                    Text("Trim silence")
                    Text("Removes silence from the start and end.")
                }
            } header: {
                Text("Microphone")
            } footer: {
                // Only when something is wrong. The general case needed no
                // explaining, and a footer that is always there is one more
                // line to read past every time.
                if let missingDeviceNote {
                    Text(missingDeviceNote).settingsFootnote()
                }
            }

            Section {
                Toggle(isOn: model.binding(\.advanced.streamingTranscribeEnabled)) {
                    Text("Transcribe while you speak")
                    Text("Reduces the wait after long dictations.")
                }

                Toggle(isOn: model.binding(\.advanced.fastTypingEnabled)) {
                    Text("Type short results directly")
                    Text("Longer results are pasted instead.")
                }
            } header: {
                Text("Text Output")
            }
        }
        .paneStyle()
        // The microphone is open only while this pane is on screen. macOS
        // shows its recording indicator throughout, which is honest and is
        // what the Sound pane does too.
        .onAppear { model.startInputPreview() }
        .onDisappear { model.stopInputPreview() }
    }

    /// Combinations are offered alongside single keys, and whatever is
    /// configured is always in the list -- a hand-edited pairing must be
    /// selectable rather than leaving the picker showing something else.
    private var triggerOptions: [TriggerCombo] {
        TriggerCombo.pickerOptions(including: model.settings.triggerCombo)
    }

    /// The empty string stands for "System Default", because `Picker` needs a
    /// concrete tag and the setting's own absence is nil.
    private var deviceSelection: Binding<String> {
        Binding(
            get: { model.settings.inputDevice ?? "" },
            set: { new in model.change { $0.inputDevice = new.isEmpty ? nil : new } }
        )
    }

    /// A configured microphone that is not plugged in stays selected and stays
    /// visible. Silently falling back to the default is how you end up recording
    /// from the wrong device without ever being told.
    private var missingDeviceNote: String? {
        guard let configured = model.settings.inputDevice,
              !model.inputDevices.contains(configured)
        else { return nil }
        return "“\(configured)” isn't connected. Recording falls back to the "
            + "system default until it is."
    }
}

// MARK: - Speech model

private struct SpeechModelPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.rows, id: \.model) { row in
                    ModelRowView(row: row, model: model)
                }
            } header: {
                Text("Transcription runs on this Mac. Nothing you dictate leaves your device.")
                    .settingsFootnote()
            } footer: {
                // Only once there is something to remove. On a fresh install
                // the only model present is the bundled one, so this was
                // describing a button that appears nowhere on the pane -- the
                // same orphaned explanation the usage footnote had.
                if model.rows.contains(where: \.isRemovable) {
                    Text("The model included with the app can't be removed.")
                        .settingsFootnote()
                }
            }

            Section {
                Picker("Language", selection: Binding(
                    get: { model.settings.language },
                    set: { new in model.change { $0.language = new } }
                )) {
                    ForEach(languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
            } footer: {
                Text("Automatic detects the language as you speak. "
                     + "Choosing one is more accurate.")
                .settingsFootnote()
            }
        }
        .paneStyle()
    }

    /// The common set, plus whatever the config already names -- a hand-edited
    /// code has to stay selected rather than quietly reading as something else.
    private var languages: [Language] {
        Language.pickerOptions(including: model.settings.language)
    }
}

private struct ModelRowView: View {
    let row: ModelRow
    @ObservedObject var model: SettingsModel

    private var isSelected: Bool { row.model == model.settings.transcriptionModel }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if row.isDownloading {
                    // Determinate when the total is known, indeterminate before
                    // then -- a bar pinned at zero reads as a stalled download.
                    if let progress = row.progress {
                        ProgressView(value: progress).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
            }

            Spacer(minLength: 8)

            if let badge = row.badge {
                StatusBadge(badge)
            } else if let action = row.action {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    switch action {
                    case .download: model.download(row.model)
                    case .cancel: model.cancelDownload(row.model)
                    case .remove: model.remove(row.model)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        // The whole row selects, not just the circle: a 15pt target for the
        // primary action of the pane would be the only fiddly thing in it.
        .contentShape(Rectangle())
        .onTapGesture { model.select(row.model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // The trait alone was a lie: it said "button" to VoiceOver while the
        // only way to activate the row was a tap gesture, which VoiceOver
        // cannot perform. Selecting a model is this pane's primary action and
        // was unreachable without a mouse.
        .accessibilityAction { model.select(row.model) }
    }
}

// MARK: - Vocabulary

private struct VocabularyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                DebouncedEditor(
                    text: VocabularyText.format(model.settings.vocabulary),
                    placeholder: "Siobhan\nKubernetes\nKPI",
                    model: model
                ) { text in
                    model.change { $0.vocabulary = VocabularyText.parse(text) }
                }
            } header: {
                Text("Terms")
            } footer: {
                Text("Names, acronyms and jargon to favour when transcribing.")
                    .settingsFootnote()
            }

            Section {
                DebouncedEditor(
                    text: PhoneticText.format(model.settings.phoneticCorrections),
                    placeholder: "get hub: GitHub\nsequel: SQL",
                    model: model
                ) { text in
                    model.change { $0.phoneticCorrections = PhoneticText.parse(text) }
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text("Replacements applied after transcribing.")
                .settingsFootnote()
            }
        }
        .paneStyle()
    }
}

/// A text area that writes its contents back a moment after typing stops.
///
/// Committing on every keystroke would revalidate and rewrite the config file
/// per character; committing only on close would lose the edit if the app
/// quit. The debounce is registered with the model as well, so closing the
/// window flushes whatever is still pending.
private struct DebouncedEditor: View {
    let text: String
    /// A worked example rather than a restatement of the footer. The format is
    /// easier to copy than to describe, and an empty grey box teaches nothing.
    let placeholder: String
    @ObservedObject var model: SettingsModel
    let commit: (String) -> Void

    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $draft)
            // The system font, not monospaced: this is a list of words, not
            // code, and a monospaced block in a settings window reads as a
            // debug surface.
            .font(.body)
            .frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(6)
            // Styled as the editable field it is. A plain filled rectangle
            // looked like a disabled area rather than somewhere to type.
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            )
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        // Clicks belong to the editor underneath.
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                draft = text
                loaded = true
            }
            .task(id: draft) {
                // Fires once on appear too, which is why the no-op is guarded:
                // otherwise opening the pane would rewrite the config.
                guard loaded, draft != text else { return }
                model.pendingEdit = { commit(draft) }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                commit(draft)
                model.pendingEdit = nil
            }
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                PermissionRowView(
                    title: "Microphone",
                    detail: "Records your voice while you hold the trigger key.",
                    isGranted: Permissions.hasMicrophone,
                    pane: .microphone,
                    request: { done in
                        Task {
                            _ = await Permissions.requestMicrophone()
                            done()
                        }
                    },
                    model: model
                )
                PermissionRowView(
                    title: "Input Monitoring",
                    detail: "Lets Open Whisper spot your trigger key. It watches "
                        + "for that one key and nothing else.",
                    isGranted: Permissions.hasInputMonitoring,
                    pane: .inputMonitoring,
                    request: { done in
                        Permissions.requestInputMonitoring()
                        done()
                    },
                    model: model
                )
                PermissionRowView(
                    title: "Accessibility",
                    detail: "Types your words into whatever app you're using.",
                    isGranted: Permissions.hasPostEvent,
                    pane: .accessibility,
                    request: { done in
                        Permissions.requestPostEvent()
                        done()
                    },
                    model: model
                )
            } header: {
                // Reading the revision here is what ties this pane to the
                // poll: it re-renders when the counter moves, which re-reads
                // each grant. Deliberately not `.id(revision)` -- that rebuilds
                // the rows from scratch every second and resets their state.
                Text(model.permissionsNeedAttention
                     ? "These permissions are granted in System Settings. "
                       + "macOS asks for each one separately."
                     : readyMessage)
                .settingsFootnote()
            }
        }
        .paneStyle()
    }

    /// The end of setup is the only moment the app can be sure someone is
    /// looking and has nothing left to do, so it is where the one instruction
    /// that matters belongs.
    ///
    /// It names the user's own trigger key rather than a default they may have
    /// changed. "Hold your trigger key" is useless to someone who has never
    /// heard the phrase and does not yet know which key it means.
    private var readyMessage: String {
        let key = model.settings.triggerCombo?.displayName ?? "your trigger key"
        return "Open Whisper is ready. Hold \(key) to dictate."
    }
}

private struct PermissionRowView: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let pane: Permissions.SettingsPane
    let request: (@escaping () -> Void) -> Void
    @ObservedObject var model: SettingsModel

    /// macOS shows its prompt once per app. After that, asking again returns the
    /// standing answer and displays nothing, so a button that only ever prompts
    /// looks broken -- it becomes "Open Settings" instead.
    @State private var hasPrompted = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isGranted {
                Button(hasPrompted ? "Open System Settings" : "Grant") {
                    if hasPrompted {
                        if let url = Permissions.settingsURL(for: pane) {
                            NSWorkspace.shared.open(url)
                        }
                    } else {
                        hasPrompted = true
                        request { model.refreshPermissions() }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// The input level, drawn the way System Settings draws it.
///
/// Segments rather than a continuous bar: a `ProgressView` reads as "how far
/// through something am I", which is the wrong question. A row of discrete
/// ticks reads as a meter, which is the convention every audio app on the
/// platform already shares with the Sound pane.
private struct InputLevelMeter: View {
    let meter: LevelMeter
    let isRunning: Bool

    /// Smoothed for the eye, not for accuracy. Raw peak readings arrive at an
    /// uneven rate and jitter hard enough to look broken.
    @State private var level: Double = 0

    private static let segmentCount = 16
    /// Matches the pill's own scaling (`value * 8`), so the two surfaces never
    /// disagree about how loud the same voice is.
    private static let gain: Double = 8
    private static let sampleInterval = Duration.milliseconds(50)

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fill(for: index))
                    .frame(width: 3, height: 11)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
        .task(id: isRunning) {
            guard isRunning else {
                level = 0
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                if Task.isCancelled { return }
                let reading = min(Double(meter.read()) * Self.gain, 1)
                // Fast attack, slow release: a meter that fell as quickly as it
                // rose would flicker on every syllable gap. Real ones lag on
                // the way down for exactly this reason.
                level = reading > level ? reading : level * 0.82 + reading * 0.18
            }
        }
    }

    private func fill(for index: Int) -> AnyShapeStyle {
        let threshold = Double(index) / Double(Self.segmentCount - 1)
        guard isRunning, level >= threshold, level > 0.01 else {
            return AnyShapeStyle(.quaternary)
        }
        // The top two segments warn rather than decorate: they are the ones
        // that mean clipping, and a meter that never changes colour never
        // tells you that.
        return AnyShapeStyle(index >= Self.segmentCount - 2 ? Color.orange : Color.accentColor)
    }
}

/// A non-interactive status chip.
///
/// Deliberately built to a small bordered button's metrics -- same height, same
/// corner radius -- because it shares a column with them. A capsule at caption
/// size sat visibly higher and smaller than the Download button one row below
/// it, which made the column look misaligned rather than deliberate.
private struct StatusBadge: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(text)
    }
}

// MARK: - Shared styling

private extension View {
    /// One place for the pane chrome, so seven panes cannot drift apart.
    func paneStyle() -> some View {
        formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Section headers and footers are explanatory text, not labels, and should
    /// read as the secondary voice they are.
    func settingsFootnote() -> some View {
        font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Bindings

private extension SettingsModel {
    /// A binding straight onto a `Settings` field, routed through `change` so
    /// every write still goes through validation and persistence.
    func binding(_ path: WritableKeyPath<OpenWhisperCore.Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: path] },
            set: { new in self.change { $0[keyPath: path] = new } }
        )
    }

    /// The same, for a field that is not itself a Bool but is presented as one.
    func binding<T>(
        _ path: WritableKeyPath<OpenWhisperCore.Settings, T>,
        as toBool: @escaping (T) -> Bool,
        to fromBool: @escaping (Bool) -> T
    ) -> Binding<Bool> {
        Binding(
            get: { toBool(self.settings[keyPath: path]) },
            set: { new in self.change { $0[keyPath: path] = fromBool(new) } }
        )
    }
}
