import AppKit
import OpenWhisperCore
import SwiftUI

// Ported from overlay.swift at the repo root.
//
// Plan §1 puts the pill's look and behaviour off-limits for redesign, so every
// view below -- OverlayModel, PillBarsView, VisualEffectView,
// OverlayContentView, TransparentHostingView, OverlayPanel -- is the original
// rendering code unchanged: same states, same icons, same Liquid Glass default,
// same --solid capsule variant, same sizes, same animation curves. The comments
// explaining *why* the geometry is what it is are kept with it, since they are
// the reason the numbers cannot be casually adjusted.
//
// Two things necessarily differ, and only these two:
//
//  1. The stdin JSON protocol is gone. The overlay was a separate process fed
//     newline-delimited JSON; in one process those become direct calls on
//     `OverlayPill`.
//  2. Icon lookup. The original resolved icons as siblings of its executable,
//     which worked because the overlay binary was itself installed into
//     Contents/Resources. This executable lives in Contents/MacOS, so the
//     sibling trick would look in the wrong directory; it asks the bundle
//     instead, and falls back to the repo layout for `swift run`.

// MARK: - Pill Icon Loading

let pillIconDirectory: String = {
    // Bundled: Contents/Resources/SVG icons for menu bar/
    if let resources = Bundle.main.resourceURL {
        let bundled = resources.appendingPathComponent("SVG icons for menu bar")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
    }
    // Source mode (`swift run`): the repo root, two levels up from swift/.
    let executable = CommandLine.arguments[0]
    let executableDirectory = (executable as NSString).deletingLastPathComponent
    return (executableDirectory as NSString).appendingPathComponent("SVG icons for menu bar")
}()

/// Loads one of the shared SVGs as a template image.
///
/// Internal rather than file-private: the status menu draws the app's mark from
/// the same folder, and two copies of this would be two places for the bundle
/// path to go wrong.
func loadPillIcon(_ filename: String) -> NSImage? {
    let path = (pillIconDirectory as NSString).appendingPathComponent(filename)
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    image.isTemplate = true
    return image
}

private let pillIcons: [String: NSImage] = [
    "recording": loadPillIcon("circle.svg"),
    "processing": loadPillIcon("sparkle.svg"),
].compactMapValues { $0 }

// MARK: - Model

/// `@MainActor` is the one addition to this class. The original was a
/// standalone executable that never enabled strict concurrency; here its
/// repeating Timer closure captures `self` in a `@Sendable` context. It drives
/// SwiftUI and the timer fires on the main run loop, so main-actor isolation is
/// what it already relied on -- now stated rather than assumed.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 20

    @Published var currentState = "recording"
    @Published var levels: [CGFloat] = Array(repeating: 0.02, count: barCount)
    @Published var visible = false
    @Published var elapsedSeconds: Int = 0

    private var timer: Timer?
    private var recordStart: Date?

    // SF Symbol fallback used only if the SVG fails to load. Same
    // state→symbol mapping as the SVGs above.
    var sfSymbol: String {
        currentState == "recording" ? "circle.fill" : "sparkle"
    }

    var pillIcon: NSImage? {
        switch currentState {
        case "recording": pillIcons["recording"]
        case "transcribing", "cleaning": pillIcons["processing"]
        default: nil
        }
    }

    var isRecording: Bool { currentState == "recording" }

    var elapsedLabel: String {
        let s = elapsedSeconds
        let mm = s / 60
        let ss = s % 60
        return String(format: "%d:%02d", mm, ss)
    }

    func pushLevel(_ value: CGFloat) {
        let clamped = min(max(value * 8, 0.02), 1.0)
        levels.append(clamped)
        if levels.count > Self.barCount {
            levels.removeFirst()
        }
    }

    func resetLevels() {
        levels = Array(repeating: 0.02, count: Self.barCount)
    }

    func startTimer() {
        recordStart = Date()
        elapsedSeconds = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            // The closure is typed @Sendable, but a timer scheduled on the
            // main run loop only ever fires on the main thread — which is the
            // assumption the original already ran on, stated explicitly.
            MainActor.assumeIsolated {
                guard let self, let start = self.recordStart else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
        recordStart = nil
    }
}

// MARK: - Bar visualiser
//
// Single unified view that draws the waveform during recording (20 bars
// driven by live audio levels) and a sine-wave pulse during processing
// (28 bars driven by time). When the state transitions, the bar count
// animates from 20 → 28 with the new bars sliding in from the trailing
// edge — and the timer slot to the left collapses to 0pt at the same
// time, so the new bars effectively scroll into the timer's space.

struct PillBarsView: View {
    @ObservedObject var model: OverlayModel

    static let recordingBars = 20
    static let restingBars = 28
    static let barMaxHeight: CGFloat = 20
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2

    // Frame widths chosen so the pill is the SAME total width in both
    // states. The natural bar-content widths (98 and 138) differ by 40pt;
    // the timer slot is 38pt. Bumping the recording frame by 2pt of trailing
    // slack closes that 2pt gap, so:
    //   recording: icon(20) + 10 + timer(38) + 10 + bars(100) = 178pt
    //   resting:   icon(20) + 10 + timer( 0) + 10 + bars(138) = 178pt
    // Identical pill widths means no panel resize is needed mid-session.
    //
    // The two 10s are the HStack spacing in OverlayContentView, written out
    // again in pinnedContentWidth. Change the spacing and both have to move,
    // or the pill's declared width stops matching what is inside it.
    static let recordingWidth: CGFloat = 100
    static var restingWidth: CGFloat {
        CGFloat(restingBars) * barWidth + CGFloat(restingBars - 1) * barSpacing
    }

    var body: some View {
        let count = model.isRecording ? Self.recordingBars : Self.restingBars
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: Self.barSpacing) {
                ForEach(0..<count, id: \.self) { i in
                    bar(index: i, time: t)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                }
            }
        }
        .frame(height: Self.barMaxHeight)
        .animation(.easeInOut(duration: 0.45), value: model.isRecording)
    }

    private func bar(index: Int, time: TimeInterval) -> some View {
        let metrics = barMetrics(index: index, time: time)
        return RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.primary.opacity(metrics.opacity))
            .frame(width: Self.barWidth, height: metrics.height)
    }

    private func barMetrics(index: Int, time: TimeInterval) -> (height: CGFloat, opacity: Double) {
        if model.isRecording {
            let level = index < model.levels.count ? model.levels[index] : 0.02
            return (3 + level * 17, 0.85)
        }
        let phase = Double(index) / Double(Self.restingBars) * .pi * 3
        let h = (sin(time * 2.5 + phase) + 1) / 2
        return (3 + CGFloat(h) * 14, 0.85)
    }
}

// MARK: - NSVisualEffectView wrapper (fallback for macOS < 26)

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Pill content

struct OverlayContentView: View {
    @ObservedObject var model: OverlayModel

    private let cyan = Color(red: 10 / 255, green: 170 / 255, blue: 210 / 255)

    /// How much of the glass material is drawn. 1.0 is full strength.
    ///
    /// `.regular` is the thick variant, chosen for its edge lensing; this takes
    /// some of its density back without giving up the bevel that `.clear`
    /// cannot produce.
    private static let glassStrength: Double = 0.75

    /// A capsule-shaped drop shadow, and nothing else.
    ///
    /// `.shadow` on the glass container produced a rectangle: SwiftUI derives a
    /// shadow from what the view renders, and the container reports its
    /// rectangular bounds rather than the capsule the material draws inside
    /// them. Stating the shape is the fix.
    ///
    /// The capsule is then punched back out of itself with `destinationOut`,
    /// leaving only the shadow it cast. Without that, a solid fill would sit
    /// behind semi-transparent glass and darken the pill from within.
    private var pillShadow: some View {
        Capsule()
            .fill(.black)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
            .overlay { Capsule().fill(.black).blendMode(.destinationOut) }
            .compositingGroup()
    }

    private let iconWidth: CGFloat = 20
    private let timerWidth: CGFloat = 38

    var body: some View {
        let iconColor: Color = .primary

        // Pin the HStack content to a fixed width so the pill does not
        // change size between states. Both states have content width 174:
        //   recording: icon(16) + 10 + timer(38) + 10 + bars(100) = 174
        //   resting:   icon(16) + 10 + timer( 0) + 10 + bars(138) = 174
        let isRecording = model.isRecording
        let visualWidth = isRecording
            ? PillBarsView.recordingWidth
            : PillBarsView.restingWidth
        let pinnedContentWidth: CGFloat =
            iconWidth + 10 + timerWidth + 10 + PillBarsView.recordingWidth

        let pill = HStack(spacing: 10) {
            Group {
                if let icon = model.pillIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18.5, height: 18.5)
                } else {
                    Image(systemName: model.sfSymbol)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundColor(iconColor)
            .frame(width: iconWidth, alignment: .center)

            Text(model.elapsedLabel)
                // SF Pro with tabular figures, rather than SF Mono.
                //
                // The timer needs digits of equal width or it changes width as
                // it counts, shoving the waveform sideways every few seconds.
                // `design: .monospaced` fixes that by switching to SF Mono,
                // which brings the slashed zero and the code-editor look with
                // it. `.monospacedDigit()` asks for the same thing SF Pro
                // already has: the tabular figures Apple uses for clocks.
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(iconColor.opacity(0.85))
                .frame(width: isRecording ? timerWidth : 0, alignment: .leading)
                .opacity(isRecording ? 1 : 0)
                .clipped()

            PillBarsView(model: model)
                .frame(width: visualWidth, alignment: .leading)
        }
        .frame(width: pinnedContentWidth, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.easeInOut(duration: 0.45), value: isRecording)

        Group {
            if #available(macOS 26.0, *) {
                // `.regular`, the standard Liquid Glass material.
                //
                // This went `.regular` -> `.clear` -> back again, and the round
                // trip is the useful part. `.clear` is the most transmissive
                // variant Apple ships, so it shows the most desktop -- but it
                // is also thin, and the edge lensing that makes glass read as
                // a physical object is a property of the material's thickness.
                // Wanting "more bevel" and "more clarity" at once is wanting
                // two ends of one dial. `.regular` picks the bevel.
                //
                // There is no bevel parameter to reach for instead: the Glass
                // API offers the variant, `.tint` and `.interactive`, and
                // nothing else. Anything more would have to be a painted-on
                // rim, which is not refraction and looks like it.
                //
                // Fading the material is not a third option either -- it makes
                // the pill paler rather than clearer, since the refraction
                // weakens along with everything else. Tried twice, reverted
                // twice.
                //
                // GlassEffectContainer lets the system render the shape as one
                // continuous glass surface; without it each glass view is
                // sampled independently and the effect flattens.
                // `.interactive()` adds the responsive light play.
                // The material sits behind the content, not over it, so its
                // strength can be dialled without taking the text and bars
                // with it. Fading `pill.glassEffect(...)` fades the whole pill
                // and reads as washed out -- learned twice.
                pill.background {
                    GlassEffectContainer {
                        Color.clear.glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .opacity(Self.glassStrength)
                    .background { pillShadow }
                }
            } else {
                // macOS 14/15 have no Liquid Glass; the closest the older
                // material stack gets.
                pill.background(
                    ZStack {
                        VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                            .clipShape(Capsule())
                        Capsule().fill(cyan.opacity(0.4))
                    }
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                )
            }
        }
        .scaleEffect(model.visible ? 1.0 : 0.95)
        .opacity(model.visible ? 1.0 : 0.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.visible)
        .padding(12)
    }
}

// MARK: - Transparent Hosting View

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Remove the default opaque background that NSHostingView draws
        window?.backgroundColor = .clear
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layer?.isOpaque = false
            self.layer?.backgroundColor = .clear
            for subview in self.subviews {
                subview.wantsLayer = true
                subview.layer?.isOpaque = false
                subview.layer?.backgroundColor = .clear
            }
        }
    }

    override func layout() {
        super.layout()
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
    }
}

// MARK: - Floating Panel

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - In-process controller

/// Replaces the overlay's stdin loop. Each case of the old JSON protocol is a
/// method here, with the body it had in the original's `switch`.
@MainActor
final class OverlayPill {

    private let model = OverlayModel()
    private var panel: OverlayPanel?
    private var hostingView: TransparentHostingView<OverlayContentView>?
    private var style: OverlayStyle

    private let meter: LevelMeter
    private var levelTimer: Timer?

    /// 20Hz, matching `PillBarsView`'s own `TimelineView(minimumInterval: 0.05)`
    /// so a new level lands on every redraw rather than on some of them.
    ///
    /// Plan §4 says "~10 Hz", which is what the Python fed and what this first
    /// did — but one push shifts the 20-bar window by one bar, so 10Hz means
    /// the waveform takes two full seconds to cross the pill, which reads as
    /// sluggish next to the processing animation. 20Hz halves that. The tap is
    /// sized to deliver well above this rate so every frame has real audio
    /// behind it; sampling faster than the audio arrives would just trade
    /// slowness back for judder.
    private static let levelSampleInterval: TimeInterval = 1.0 / 20.0

    init(style: OverlayStyle, meter: LevelMeter) {
        self.style = style
        self.meter = meter
    }

    /// Live config reload. Turning the pill off tears the panel down; turning
    /// it back on rebuilds it on the next show.
    func apply(style newStyle: OverlayStyle) {
        guard newStyle != style else { return }
        style = newStyle
        teardown()
    }

    private func makePanelIfNeeded() {
        guard panel == nil, style != .off else { return }

        let view = TransparentHostingView(
            rootView: OverlayContentView(model: model)
        )
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .clear

        let newPanel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .transient]
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = view

        panel = newPanel
        hostingView = view
    }

    private func teardown() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    // MARK: Commands

    func show(state: String = "recording") {
        guard style != .off else { return }
        makePanelIfNeeded()
        guard let panel, let hostingView else { return }

        // All state setup before the panel is on-screen happens with
        // animations disabled, so the SwiftUI view doesn't mid-animate from
        // the previous session's leftover state when re-shown.
        var noAnim = Transaction()
        noAnim.disablesAnimations = true
        withTransaction(noAnim) {
            // Size the panel for the WIDER (resting) state so the SwiftUI
            // content has room as it later transitions out of recording.
            model.currentState = "transcribing"
        }
        hostingView.layoutSubtreeIfNeeded()
        let maxSize = hostingView.fittingSize
        withTransaction(noAnim) {
            model.currentState = state
            model.resetLevels()
            model.elapsedSeconds = 0
            // Force visible to a clean false so the entry spring animation
            // always plays from scratch, even if the previous hide animation
            // hadn't settled yet.
            model.visible = false
        }
        if state == "recording" {
            model.startTimer()
            startSamplingLevels()
        }
        panel.setContentSize(maxSize)
        if let screen = NSScreen.main {
            let x = (screen.frame.width - maxSize.width) / 2
            let y = screen.visibleFrame.origin.y + 42
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.alphaValue = 1
        panel.orderFront(nil)
        DispatchQueue.main.async { [model] in
            model.visible = true
        }
    }

    private func startSamplingLevels() {
        meter.reset()
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(
            withTimeInterval: Self.levelSampleInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.pushLevel(CGFloat(self.meter.read()))
            }
        }
    }

    private func stopSamplingLevels() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    func set(state: String) {
        guard style != .off else { return }
        model.currentState = state
        if state != "recording" {
            model.stopTimer()
            stopSamplingLevels()
        }
        // Don't reposition here. The pill width is constant across states, and
        // resizing the panel mid-animation causes a perceptible vertical jump.
    }

    func hide() {
        model.stopTimer()
        stopSamplingLevels()
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func quit() {
        model.stopTimer()
        teardown()
    }
}

// MARK: - Previews

#if DEBUG

/// The pill draws over whatever is behind the window, so a canvas preview
/// shows its glass against the canvas background rather than a desktop. Good
/// enough for geometry, spacing and animation; judge the material itself by
/// running the app.
private enum PillPreviewHost {
    @MainActor static let recording: OverlayModel = {
        let model = OverlayModel()
        model.currentState = "recording"
        model.visible = true
        model.elapsedSeconds = 12
        // A plausible waveform rather than a flat line.
        model.levels = (0..<OverlayModel.barCount).map { index in
            0.15 + 0.5 * abs(sin(Double(index) / 2.4))
        }
        return model
    }()

    @MainActor static let transcribing: OverlayModel = {
        let model = OverlayModel()
        model.currentState = "transcribing"
        model.visible = true
        return model
    }()
}

// `PreviewProvider` rather than the `#Preview` macro: this file imports AppKit
// as well as SwiftUI, and both SwiftUI and DeveloperToolsSupport declare a
// `Preview` type, so the macro is ambiguous here. The protocol is not.
struct PillPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            OverlayContentView(model: PillPreviewHost.recording)
                .previewDisplayName("Recording")
            OverlayContentView(model: PillPreviewHost.transcribing)
                .previewDisplayName("Transcribing")
        }
        .frame(width: 320, height: 80)
    }
}

#endif
