import AppKit

/// A small floating panel near the bottom of the screen: voice, time left,
/// pause and stop, and the sentence being read with the current word highlighted.
/// It never takes focus from the app you're reading in.
final class MiniPlayer {
    var onPause: (() -> Void)?
    var onStop: (() -> Void)?

    private static let width: CGFloat = 440
    private static let textFont = NSFont.systemFont(ofSize: 14)

    private let panel: NSPanel
    private let wave = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let stopButton = NSButton()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 110),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.alphaValue = 0

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        // A mask image (not a layer corner radius) so the window's shadow follows the rounded shape.
        background.maskImage = Self.roundedMask(radius: 16)
        panel.contentView = background

        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        for (button, symbol, label, action) in [(pauseButton, "pause.fill", "Pause", #selector(pauseClicked)),
                                                (stopButton, "xmark", "Stop", #selector(stopClicked))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imageScaling = .scaleProportionallyDown
            button.bezelStyle = .circular
            button.isBordered = true
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = label
        }

        textLabel.font = Self.textFont
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.isSelectable = false

        [wave, status, pauseButton, stopButton, textLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview($0)
        }
        NSLayoutConstraint.activate([
            wave.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            wave.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 18),
            wave.heightAnchor.constraint(equalToConstant: 18),
            status.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 8),
            status.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: pauseButton.leadingAnchor, constant: -8),
            stopButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stopButton.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            pauseButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -4),
            pauseButton.centerYAnchor.constraint(equalTo: stopButton.centerYAnchor),
            textLabel.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            textLabel.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            textLabel.topAnchor.constraint(equalTo: stopButton.bottomAnchor, constant: 8),
            textLabel.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
        ])
        textLabel.preferredMaxLayoutWidth = Self.width - 32
    }

    func show() {
        hideWork?.cancel()
        guard !isVisible else { return }
        isVisible = true
        position()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    /// Fades out after a short delay, so it doesn't flicker between utterances.
    func hide(after delay: TimeInterval = 0.6) {
        guard isVisible else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.isVisible = false
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { [weak self] in
                if self?.isVisible == false { self?.panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func update(_ snapshot: Speaker.Snapshot?, voice: String, phase: CGFloat, loading: Bool) {
        let paused = snapshot?.isPaused ?? false
        wave.image = SpokenText.activityImage(size: 18, phase: phase, snapshot: snapshot, color: .controlAccentColor)
        let name = Voices.displayName(voice)
        if loading {
            status.stringValue = "Loading \(name)…"
        } else if snapshot?.isWaiting == true {
            status.stringValue = "\(name) · preparing the next sentence…"
        } else if paused {
            status.stringValue = "\(name) · paused"
        } else {
            let left = SpokenText.timeLeft(snapshot?.secondsLeft)
            status.stringValue = left.isEmpty ? name : "\(name) · \(left)"
        }
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: paused ? "Resume" : "Pause")
        pauseButton.toolTip = paused ? "Resume" : "Pause"
        pauseButton.isEnabled = !loading

        let text = snapshot.map { SpokenText.attributed($0, maxLength: 150, font: Self.textFont, highlight: Settings.highlight) }
        textLabel.attributedStringValue = text ?? NSAttributedString(string: "")
        textLabel.isHidden = (text?.length ?? 0) == 0
        resizeToFit()
    }

    private func resizeToFit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = textLabel.isHidden ? 48 : min(max(content.fittingSize.height, 60), 140)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size = NSSize(width: Self.width, height: height)  // grow upward from the bottom edge
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.width / 2, y: visible.minY + 48))
    }

    @objc private func pauseClicked() { onPause?() }
    @objc private func stopClicked() { onStop?() }
}
