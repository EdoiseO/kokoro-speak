import AppKit

/// Menu header while speaking: status line, the text being read with the
/// current word highlighted, and a progress bar.
final class NowSpeakingView: NSView {
    private static let width: CGFloat = 290
    private static let textFont = NSFont.systemFont(ofSize: 13)

    private let wave = NSImageView()
    private let status = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 96))
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .controlAccentColor
        textLabel.font = Self.textFont
        textLabel.maximumNumberOfLines = 3
        textLabel.isSelectable = false
        textLabel.preferredMaxLayoutWidth = Self.width - 28
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small

        [wave, status, textLabel, progress].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            wave.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            wave.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 14),
            wave.heightAnchor.constraint(equalToConstant: 14),
            status.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 5),
            status.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            status.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            textLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textLabel.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 6),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(_ snapshot: Speaker.Snapshot?, voice: String, phase: CGFloat, loading: Bool) {
        let paused = snapshot?.isPaused ?? false
        wave.image = SpokenText.activityImage(size: 14, phase: phase, snapshot: snapshot, color: .controlAccentColor)
        let name = Voices.displayName(voice)
        if loading {
            status.stringValue = "Loading \(name)…"
        } else if snapshot?.isWaiting == true {
            status.stringValue = "Preparing the next sentence…"
        } else if paused {
            status.stringValue = "Paused · \(name)"
        } else {
            let left = SpokenText.timeLeft(snapshot?.secondsLeft)
            status.stringValue = left.isEmpty ? "Speaking · \(name)" : "Speaking · \(left)"
        }
        textLabel.attributedStringValue = snapshot.map {
            SpokenText.attributed($0, maxLength: 110, font: Self.textFont, highlight: Settings.highlight)
        } ?? NSAttributedString(string: "")
        progress.doubleValue = snapshot?.fraction ?? 0

        layoutSubtreeIfNeeded()
        let height = fittingSize.height
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: Self.width, height: height))
            if let item = enclosingMenuItem { item.menu?.itemChanged(item) }
        }
    }
}
