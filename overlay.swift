import AppKit
import SwiftUI

// MARK: - Stdin Protocol
// JSON lines: {"cmd":"show","state":"recording"}
//             {"cmd":"level","v":0.42}
//             {"cmd":"state","s":"transcribing"}
//             {"cmd":"hide"}
//             {"cmd":"quit"}
//
// CLI: pass --solid to use the original opaque cyan capsule. Default is the
// macOS 26 Liquid Glass material.

struct Command: Decodable {
    let cmd: String
    var state: String?
    var s: String?
    var v: Double?
}

// MARK: - Pill Icon Loading
//
// Loads the custom SVG icons. Each NSImage is flagged as a template so
// SwiftUI's .foregroundColor() tints it. If a file is missing the
// dictionary key is dropped via compactMapValues, and the view falls
// back to the SF Symbol path.
//
// Lookup paths, in order:
//   1. Inside an .app bundle, this binary lives at
//      `…/Open Whisper.app/Contents/Resources/overlay`, so the icons
//      are right next to it (also under Contents/Resources/).
//      That's the same directory as the binary, so the sibling lookup
//      below works for bundled mode too.
//   2. Source mode: the binary is at the project root, icons in the
//      "SVG icons for menu bar/" sibling — same sibling lookup.
// One path resolution covers both modes.

private let pillIconDir: String = {
    let exePath = CommandLine.arguments[0]
    let exeDir = (exePath as NSString).deletingLastPathComponent
    return (exeDir as NSString).appendingPathComponent("SVG icons for menu bar")
}()

private func loadPillIcon(_ filename: String) -> NSImage? {
    let path = (pillIconDir as NSString).appendingPathComponent(filename)
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    img.isTemplate = true
    return img
}

private let pillIcons: [String: NSImage] = [
    "recording":  loadPillIcon("circle.svg"),
    "processing": loadPillIcon("sparkle.svg"),
].compactMapValues { $0 }

// MARK: - Model

class OverlayModel: ObservableObject {
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
        case "recording":                return pillIcons["recording"]
        case "transcribing", "cleaning": return pillIcons["processing"]
        default:                          return nil
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
            guard let self, let start = self.recordStart else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(start))
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
    //   recording: icon(16) + 10 + timer(38) + 10 + bars(100) = 174pt
    //   resting:   icon(16) + 10 + timer( 0) + 10 + bars(138) = 174pt
    // Identical pill widths means no panel resize is needed mid-session.
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
        return (3 + CGFloat(h) * 14, 0.55)
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
    let translucent: Bool

    private let cyan = Color(red: 10/255, green: 170/255, blue: 210/255)
    private let iconWidth: CGFloat = 20
    private let timerWidth: CGFloat = 38

    var body: some View {
        let iconColor: Color = translucent ? .primary : .white

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
                        .frame(width: 17.5, height: 17.5)
                } else {
                    Image(systemName: model.sfSymbol)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundColor(iconColor)
            .frame(width: iconWidth, alignment: .center)

            Text(model.elapsedLabel)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
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
            if translucent {
                if #available(macOS 26.0, *) {
                    // Pure clear glass — no cyan tint. Lets the Liquid Glass
                    // refraction read clearly. The cyan brand colour comes
                    // through the icon and the recording dot.
                    pill.glassEffect(.regular, in: .capsule)
                } else {
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
            } else {
                pill.background(
                    Capsule()
                        .fill(cyan)
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

class TransparentHostingView<Content: View>: NSHostingView<Content> {
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

class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Entry Point

@main
enum Overlay {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let translucent = !CommandLine.arguments.contains("--solid")

        let model = OverlayModel()

        let hostingView = TransparentHostingView(
            rootView: OverlayContentView(model: model, translucent: translucent)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 48)
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = .clear

        let panel = OverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView

        func reposition() {
            let size = hostingView.fittingSize
            panel.setContentSize(size)
            if let screen = NSScreen.main {
                let x = (screen.frame.width - size.width) / 2
                let y = screen.visibleFrame.origin.y + 42
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }

        // Read stdin on background thread
        DispatchQueue.global(qos: .userInteractive).async {
            let decoder = JSONDecoder()
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let cmd = try? decoder.decode(Command.self, from: data) else { continue }

                DispatchQueue.main.async {
                    switch cmd.cmd {
                    case "show":
                        let state = cmd.state ?? "recording"
                        // All state setup before the panel is on-screen
                        // happens with animations disabled, so the SwiftUI
                        // view doesn't mid-animate from the previous
                        // session's leftover state when re-shown.
                        var noAnim = Transaction()
                        noAnim.disablesAnimations = true
                        withTransaction(noAnim) {
                            // Size the panel for the WIDER (resting) state
                            // so the SwiftUI content has room as it later
                            // transitions out of recording.
                            model.currentState = "transcribing"
                        }
                        hostingView.layoutSubtreeIfNeeded()
                        let maxSize = hostingView.fittingSize
                        withTransaction(noAnim) {
                            model.currentState = state
                            model.resetLevels()
                            model.elapsedSeconds = 0
                            // Force visible to a clean false so the entry
                            // spring animation always plays from scratch,
                            // even if the previous hide animation hadn't
                            // settled yet.
                            model.visible = false
                        }
                        if state == "recording" {
                            model.startTimer()
                        }
                        panel.setContentSize(maxSize)
                        if let screen = NSScreen.main {
                            let x = (screen.frame.width - maxSize.width) / 2
                            let y = screen.visibleFrame.origin.y + 42
                            panel.setFrameOrigin(NSPoint(x: x, y: y))
                        }
                        panel.alphaValue = 1
                        panel.orderFront(nil)
                        DispatchQueue.main.async {
                            model.visible = true
                        }

                    case "level":
                        if let v = cmd.v {
                            model.pushLevel(CGFloat(v))
                        }

                    case "state":
                        if let s = cmd.s {
                            model.currentState = s
                            if s != "recording" {
                                model.stopTimer()
                            }
                            // Don't call reposition() here. The pill width
                            // is constant across states, and resizing the
                            // panel mid-animation causes a perceptible
                            // vertical jump.
                        }

                    case "hide":
                        model.stopTimer()
                        model.visible = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            panel.orderOut(nil)
                        }

                    case "quit":
                        app.terminate(nil)

                    default:
                        break
                    }
                }
            }
            DispatchQueue.main.async { app.terminate(nil) }
        }

        app.run()
    }
}
