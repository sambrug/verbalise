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
        case .triggerKey: TriggerKeyPane(model: model)
        case .speechModel: SpeechModelPane(model: model)
        case .audio: AudioPane(model: model)
        case .textOutput: TextOutputPane(model: model)
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

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                )) {
                    Text("Open at login")
                    Text("Open Whisper runs in the menu bar with no window.")
                }

                Toggle(isOn: model.binding(\.overlayStyle, as: { $0 == .on }, to: { $0 ? .on : .off })) {
                    Text("Show recording overlay")
                    Text("A floating pill shows the microphone level while you speak.")
                }

                Toggle(isOn: model.binding(\.soundEnabled)) {
                    Text("Play a sound when recording starts and stops")
                }
            }

            Section {
                LabeledContent("Dictations",
                               value: StatsFormatter.grouped(model.stats.totalRecordings))
                LabeledContent("Words",
                               value: StatsFormatter.grouped(model.stats.totalWords))
                // Only once there is enough to be worth saying. "0 minutes" on
                // a fresh install is a worse greeting than no row at all.
                if let saved = StatsFormatter.timeSaved(model.stats) {
                    LabeledContent("Time saved typing", value: saved)
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Time saved compares typing at 40 words a minute with "
                     + "speaking at 150. It is indicative, not a measurement.")
                .settingsFootnote()
            }

            Section {
                Button("Open Configuration File") { model.openConfigFile() }
                Button("Show Log") { model.showLog() }
            } header: {
                Text("Diagnostics")
            }
        }
        .paneStyle()
    }
}

// MARK: - Trigger key

private struct TriggerKeyPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Hold to dictate:", selection: Binding(
                    get: { model.settings.triggerKey },
                    set: { new in model.change { $0.triggerKey = new } }
                )) {
                    ForEach(options, id: \.configValue) { combo in
                        Text(combo.displayName).tag(combo.configValue)
                    }
                }
            } footer: {
                Text("Hold the key while you speak, then release. The text is "
                     + "inserted into whatever app you are using.\n"
                     + "Press Escape while recording to discard it.")
                .settingsFootnote()
            }
        }
        .paneStyle()
    }

    /// Combinations are offered alongside single keys, and whatever is
    /// configured is always in the list -- a hand-edited pairing must be
    /// selectable rather than leaving the picker showing something else.
    private var options: [TriggerCombo] {
        TriggerCombo.pickerOptions(including: model.settings.triggerCombo)
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
                Text("Transcription runs on this Mac. Nothing you say is sent to a server.")
                    .settingsFootnote()
            } footer: {
                Text("Models are stored in the app and removed when you delete it.")
                    .settingsFootnote()
            }
        }
        .paneStyle()
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
                Button(action.title) {
                    switch action {
                    case .download: model.download(row.model)
                    case .cancel: model.cancelDownload(row.model)
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
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @ObservedObject var model: SettingsModel

    /// The empty string stands for "System Default", because `Picker` needs a
    /// concrete tag and the setting's own absence is nil.
    private var deviceSelection: Binding<String> {
        Binding(
            get: { model.settings.inputDevice ?? "" },
            set: { new in model.change { $0.inputDevice = new.isEmpty ? nil : new } }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("Microphone:", selection: deviceSelection) {
                    Text("System Default").tag("")
                    Divider()
                    ForEach(model.inputDevices, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            } footer: {
                Text(missingDeviceNote ?? "System Default follows whatever you choose in "
                     + "Sound settings, including a headset as you connect it.")
                .settingsFootnote()
            }

            Section {
                Toggle(isOn: model.binding(\.advanced.trimSilenceEnabled)) {
                    Text("Trim silence")
                    Text("Removes quiet lead-in and trailing pauses before transcribing.")
                }
            }
        }
        .paneStyle()
    }

    /// A configured microphone that is not plugged in stays selected and stays
    /// visible. Silently falling back to the default is how you end up recording
    /// from the wrong device without ever being told.
    private var missingDeviceNote: String? {
        guard let configured = model.settings.inputDevice,
              !model.inputDevices.contains(configured)
        else { return nil }
        return "“\(configured)” is not connected. Recording uses the system default until it is."
    }
}

// MARK: - Text output

private struct TextOutputPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: model.binding(\.advanced.streamingTranscribeEnabled)) {
                    Text("Transcribe while you speak")
                    Text("Long dictations are transcribed in the background, "
                         + "so there is less to wait for when you let go.")
                }

                Toggle(isOn: model.binding(\.advanced.fastTypingEnabled)) {
                    Text("Type short results directly")
                    Text("Avoids touching the clipboard for short dictations. "
                         + "Longer ones are pasted and your clipboard is put back.")
                }
            }
        }
        .paneStyle()
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
                    model: model
                ) { text in
                    model.change { $0.vocabulary = VocabularyText.parse(text) }
                }
            } header: {
                Text("Vocabulary")
            } footer: {
                Text("Names, acronyms and jargon to favour when transcribing. "
                     + "One per line.")
                .settingsFootnote()
            }

            Section {
                DebouncedEditor(
                    text: PhoneticText.format(model.settings.phoneticCorrections),
                    model: model
                ) { text in
                    model.change { $0.phoneticCorrections = PhoneticText.parse(text) }
                }
            } header: {
                Text("Corrections")
            } footer: {
                Text("Words that are consistently misheard, replaced after "
                     + "transcribing. One per line, as  misheard: correct")
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
    @ObservedObject var model: SettingsModel
    let commit: (String) -> Void

    @State private var draft: String = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $draft)
            .font(.body.monospaced())
            .frame(minHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
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
                    detail: "Notices the trigger key being held. Open Whisper "
                        + "watches for that key only and never blocks it.",
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
                    detail: "Types the transcribed text into the app you are using.",
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
                     ? "Open Whisper needs these to work. macOS grants each one "
                       + "separately, and none can be granted by the app itself."
                     : "Open Whisper has everything it needs.")
                .settingsFootnote()
            } footer: {
                Text("This list updates as you grant them, so you can leave it "
                     + "open beside System Settings.")
                .settingsFootnote()
            }
        }
        .paneStyle()
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
                Button(hasPrompted ? "Open Settings…" : "Grant") {
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
            } else {
                StatusBadge("Granted")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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
