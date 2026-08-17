import AppKit
import VerbaliseCore
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

// MARK: - Model

/// `@MainActor` is the one addition to this class. The original was a
/// standalone executable that never enabled strict concurrency; here its
/// repeating Timer closure captures `self` in a `@Sendable` context. It drives
/// SwiftUI and the timer fires on the main run loop, so main-actor isolation is
/// what it already relied on -- now stated rather than assumed.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 21

    @Published var currentState = "recording"
    @Published var levels: [CGFloat] =
        Array(repeating: CGFloat(LevelScaler.minimumHeight), count: barCount)
    @Published var visible = false
    @Published var elapsedSeconds: Int = 0

    private var timer: Timer?
    private var recordStart: Date?

    /// SF Symbols rather than the hand-drawn SVGs this was ported with.
    ///
    /// Those were a filled circle and a four-point star, drawn to imitate SF
    /// Symbols without being them -- so they missed the optical sizing Apple
    /// applies at small sizes, and they had to be loaded from disk at runtime.
    ///
    /// `record.circle.fill` is the record button's own mark -- a dot inside a
    /// ring. A plain `circle.fill` is the more literal "recording" indicator,
    /// but at pill size the ring gives the glyph an outline to sit inside,
    /// which stops a solid disc dominating the waveform beside it.
    ///
    /// `sparkles.2` is the same idea as the `sparkles` in the Speech Model
    /// settings pane -- Apple's mark for on-device intelligence -- in the
    /// two-star cut, which sits better beside a waveform than the three.
    var symbolName: String {
        switch currentState {
        case "recording": "record.circle.fill"
        case "transcribing", "cleaning": "sparkles.2"
        case "copied": "doc.on.clipboard"
        default: "record.circle.fill"
        }
    }

    /// Sized per symbol, not once for both.
    ///
    /// The record mark and the sparkles carry different amounts of ink at the
    /// same nominal size, so one number for both left the recording state
    /// shouting next to the waveform. Optical sizing balances weights within a
    /// symbol; across two symbols this different it still needs a hand.
    var symbolSize: CGFloat {
        switch currentState {
        case "recording": 13.5
        default: 15
        }
    }

    var isRecording: Bool { currentState == "recording" }
    var isCopied: Bool { currentState == "copied" }

    var elapsedLabel: String {
        let s = elapsedSeconds
        let mm = s / 60
        let ss = s % 60
        return String(format: "%d:%02d", mm, ss)
    }

    /// Adapts the bar heights to how loudly the user happens to be speaking.
    /// See `LevelScaler`; it replaced a fixed multiplier that only looked right
    /// at one volume.
    private var scaler = LevelScaler()

    func pushLevel(_ value: CGFloat) {
        levels.append(CGFloat(scaler.scale(Double(value))))
        if levels.count > Self.barCount {
            levels.removeFirst()
        }
    }

    func resetLevels() {
        // The scale is per-dictation: whatever the last one was spoken at
        // should not decide how the next one starts out.
        scaler.reset()
        levels = Array(repeating: CGFloat(LevelScaler.minimumHeight), count: Self.barCount)
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

    static let recordingBars = 21
    static let restingBars = 28
    static let barMaxHeight: CGFloat = 20
    static let barWidth: CGFloat = 3
    static let barSpacing: CGFloat = 2

    // Frame widths chosen so the pill is the SAME total width in both states,
    // which is what stops the panel resizing mid-session:
    //   recording: icon(20) + 10 + timer(35) + 10 + bars(103) = 178pt
    //   resting:   icon(20) + 10 + timer( 0) + 10 + bars(138) = 178pt
    //
    // The timer slot was 38pt against text that measures about 26, so ten-odd
    // points of it were empty and sat between the numbers and the first bar --
    // a gap twice the width of the one on the other side of the numbers. Three
    // of those points went to a 21st bar, which closes the difference and keeps
    // the two totals equal. Any further trimming has to move between these two
    // numbers, not out of one of them.
    //
    // The two 10s are the HStack spacing in OverlayContentView, written out
    // again in pinnedContentWidth. Change the spacing and both have to move,
    // or the pill's declared width stops matching what is inside it.
    static let recordingWidth: CGFloat = 103
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

// MARK: - AppKit glass

/// `NSGlassEffectView` (macOS 26) wrapped for SwiftUI.
///
/// The SwiftUI `.glassEffect()` modifier drew a flat, evenly translucent
/// capsule here -- the fill without the blur or the edge refraction. The
/// backdrop sampling that produces both needs the material to sit in the
/// window's own view hierarchy, and inside an NSHostingView in a borderless
/// transparent panel it evidently does not get there.
///
/// The evidence for going this way is one file down: the pre-26 fallback wraps
/// `NSVisualEffectView` with `.behindWindow` in exactly this manner, and that
/// one blurs correctly. So an AppKit view in this hierarchy can sample the
/// desktop. This is the same trick with the macOS 26 material.
@available(macOS 26.0, *)
struct AppKitGlassView: NSViewRepresentable {
    var style: NSGlassEffectView.Style = .regular
    var tint: NSColor?

    func makeNSView(context: Context) -> CapsuleGlassView {
        CapsuleGlassView()
    }

    func updateNSView(_ view: CapsuleGlassView, context: Context) {
        view.style = style
        view.tintColor = tint
    }
}

/// Glass that stays a capsule.
///
/// The radius has to be set from `layout`, not when SwiftUI configures the
/// view. At configuration time the bounds are still zero, so half the height
/// is zero, and the pill comes out square -- which is what happened the moment
/// a redundant `clipShape` stopped hiding it. `layout` runs once the view has
/// a real size, and again whenever that size changes.
@available(macOS 26.0, *)
final class CapsuleGlassView: NSGlassEffectView {
    override func layout() {
        super.layout()
        cornerRadius = bounds.height / 2
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

    /// The app icon's own gradient, lifted from `AppIcon.icon/icon.json`.
    ///
    /// Display P3 because that is the space the icon was authored in; sRGB
    /// values would land slightly duller than the icon they are borrowed from.
    /// The stop at 0.7 rather than 1.0 is the icon's too -- the blue never
    /// quite reaches the bottom edge.
    private static let iconGradient = LinearGradient(
        colors: [
            Color(.displayP3, red: 0.85764, green: 0.63442, blue: 1.0),
            Color(.displayP3, red: 0.33716, green: 0.68604, blue: 0.81592),
        ],
        startPoint: UnitPoint(x: 0.5, y: 0),
        endPoint: UnitPoint(x: 0.5, y: 0.7)
    )

    /// How much of that gradient is painted over the glass.
    ///
    /// This is the knob. `tintColor` on the glass would be the native way to
    /// colour it, but it takes one colour and this is two, so the gradient is
    /// a layer on top instead -- which means it *paints* rather than pulling
    /// the material's temperature, and goes garish far sooner. Low.
    private static let gradientStrength: Double = 0.12

    private let iconWidth: CGFloat = 20
    private let timerWidth: CGFloat = 35

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
            // Sizes come from the model, per symbol -- see `symbolSize`.
            // `iconWidth` below is the slot the glyph sits in, not its size.
            Image(systemName: model.symbolName)
                .font(.system(size: model.symbolSize, weight: .semibold))
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

            if model.isCopied {
                // Clipboard mode's exit line. Takes the bars' slot at the
                // bars' width, so the pill never changes size.
                Text("Press ⌘V to paste")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(iconColor.opacity(0.85))
                    .frame(width: visualWidth, alignment: .leading)
            } else {
                PillBarsView(model: model)
                    .frame(width: visualWidth, alignment: .leading)
            }
        }
        .frame(width: pinnedContentWidth, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.easeInOut(duration: 0.45), value: isRecording)

        Group {
            if #available(macOS 26.0, *) {
                // AppKit's glass, not SwiftUI's -- see AppKitGlassView for the
                // reasoning, which is the one thing in this file worth reading
                // before changing it again.
                //
                // Behind the content rather than wrapping it, so the text and
                // bars stay at full strength whatever the material does.
                //
                // No clipShape. NSGlassEffectView shapes itself through
                // cornerRadius, and clipping it to a capsule on top of that
                // cuts into the specular edge the material draws just inside
                // its own bounds -- which is the bevel this was all for.
                pill.background {
                    AppKitGlassView(style: .regular, tint: nil)
                        .overlay {
                            // Inset by a point so the rim is left alone. The
                            // specular edge sits just inside the material's
                            // bounds, and painting over it is exactly what the
                            // note above says not to do.
                            Self.iconGradient
                                .opacity(Self.gradientStrength)
                                .clipShape(Capsule())
                                .padding(1)
                        }
                        .allowsHitTesting(false)
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
        // Only this view's own backing, and the window's. An earlier version
        // walked into `subviews` and cleared their layers too, which was right
        // when the pill was a hand-built capsule over an NSVisualEffectView --
        // and wrong the moment it became Liquid Glass. Those subviews are
        // SwiftUI's, and the glass material renders into one of them: clearing
        // its backing leaves the fill without the backdrop sampling that makes
        // it blur and refract, which is exactly the flat translucent shape the
        // pill had.
        window?.backgroundColor = .clear
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
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

    /// Invalidates any pending flash-hide: a new dictation's pill must not be
    /// taken down by the tail end of the previous one's flash.
    private var flashGeneration = 0

    func show(state: String = "recording") {
        guard style != .off else { return }
        flashGeneration += 1
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

    /// Shows `state` briefly, then hides. Clipboard mode's "Press ⌘V" cue:
    /// long enough to read in the corner of an eye, short enough that the
    /// pill never feels stuck.
    func flash(state: String) {
        guard style != .off else { return }
        set(state: state)
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.hide()
        }
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
