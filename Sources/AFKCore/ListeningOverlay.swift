import AppKit
import SwiftUI

/// Floating pill near the bottom of the screen that shows AFK's state (listening, pasted, notices).
/// The panel never becomes key, so the paste still lands in the user's app.
@MainActor
public final class ListeningOverlay {
    private let model = OverlayModel()
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?
    /// Bumped on every show/hide so a stale fade-out can't close a newer pill.
    private var generation = 0

    private static let panelSize = NSSize(width: 640, height: 90)
    private static let bottomInset: CGFloat = 64

    public init() {}

    public func showListening() {
        model.transcript = ""
        model.hint = nil
        model.level = 0
        show(.listening(since: Date()), autoHideAfter: nil)
    }

    public func showTranscribing() {
        show(.transcribing, autoHideAfter: nil)
    }

    /// Small dimmed hint after the timer (e.g. how to finish hands-free recording).
    public func setHint(_ hint: String?) {
        model.hint = hint
    }

    /// Live transcript shown while listening.
    public func updateTranscript(_ text: String) {
        model.transcript = text
    }

    /// Microphone loudness 0...1; smoothed so the bars don't flicker.
    public func updateLevel(_ level: Float) {
        let target = CGFloat(level)
        let rate: CGFloat = target > model.level ? 0.6 : 0.25
        model.level += (target - model.level) * rate
    }

    public func showDone(_ text: String) {
        show(.notice(symbol: "checkmark.circle.fill", tint: .green, text: text), autoHideAfter: 0.9)
    }

    public func showNotice(_ text: String, symbol: String, autoHideAfter: TimeInterval? = 3) {
        show(.notice(symbol: symbol, tint: .orange, text: text), autoHideAfter: autoHideAfter)
    }

    public func hide() {
        hideWork?.cancel()
        hideWork = nil
        generation += 1
        let current = generation
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func show(_ state: OverlayModel.State, autoHideAfter delay: TimeInterval?) {
        hideWork?.cancel()
        hideWork = nil
        generation += 1
        model.state = state

        position()
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }

        if let delay {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.bottomInset,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func makePanel() -> NSPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum State {
        case hidden
        case listening(since: Date)
        case transcribing
        case notice(symbol: String, tint: Color, text: String)
    }

    @Published var state: State = .hidden
    @Published var transcript = ""
    @Published var hint: String?
    @Published var level: CGFloat = 0
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .frame(height: 40)
            .frame(maxWidth: 600)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule().fill(Color.black.opacity(0.82)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case let .listening(since):
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(since)
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(0.55 + 0.45 * abs(sin(t * 3)))
                    WaveformBars(time: t, level: model.level)
                    if model.transcript.isEmpty {
                        Text("Listening")
                    } else {
                        Text(model.transcript)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: model.hint == nil ? 420 : 300, alignment: .leading)
                    }
                    Text(Self.elapsed(t))
                        .monospacedDigit()
                        .foregroundColor(.white.opacity(0.6))
                    if let hint = model.hint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
            }
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                Text("Transcribing…")
            }
        case let .notice(symbol, tint, text):
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundColor(tint)
                Text(text).lineLimit(1)
            }
        }
    }

    private static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Bars whose height follows the microphone level, with a small idle ripple.
private struct WaveformBars: View {
    let time: TimeInterval
    let level: CGFloat
    private let count = 9

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: height(for: i))
            }
        }
        .frame(height: 22)
    }

    private func height(for index: Int) -> CGFloat {
        let x = Double(index)
        let wave = 0.6 + 0.25 * sin(time * 7 + x * 0.9) + 0.15 * sin(time * 11.3 + x * 2.1)
        let center = Double(count - 1) / 2
        let envelope = 1 - abs(x - center) / (center + 2)
        let loudness = 0.12 + 0.88 * Double(level)
        return 3 + 19 * CGFloat(max(0, wave) * envelope * loudness)
    }
}
