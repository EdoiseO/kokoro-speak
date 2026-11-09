import AppKit

/// The voice picker shown inside the Voice submenu: a four-way group toggle
/// above a two-column list of names. Clicking a name selects it and previews it.
final class VoiceMenuView: NSView {
    var onSelect: ((String) -> Void)?

    private static let width: CGFloat = 230
    private static let rowHeight: CGFloat = 22
    private static let inset: CGFloat = 6

    private let segments = NSSegmentedControl()
    private var rows: [VoiceRow] = []
    private var group: VoiceGroup
    private var selected: String

    init(selected: String) {
        self.selected = selected
        self.group = VoiceGroup.of(selected)
        super.init(frame: .zero)

        segments.segmentCount = VoiceGroup.allCases.count
        for group in VoiceGroup.allCases {
            segments.setLabel(group.label, forSegment: group.rawValue)
            segments.setToolTip(group.accessibilityLabel, forSegment: group.rawValue)
            segments.setWidth((Self.width - Self.inset * 2 - 8) / 4, forSegment: group.rawValue)
        }
        segments.segmentStyle = .rounded
        segments.controlSize = .small
        segments.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        segments.trackingMode = .selectOne
        segments.target = self
        segments.action = #selector(groupChanged)
        addSubview(segments)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelected(_ voice: String) {
        selected = voice
        rows.forEach { $0.isChecked = $0.voice == voice }
    }

    @objc private func groupChanged() {
        group = VoiceGroup(rawValue: segments.selectedSegment) ?? .usFemale
        rebuild()
    }

    private func rebuild() {
        segments.selectedSegment = group.rawValue
        rows.forEach { $0.removeFromSuperview() }
        let voices = group.voices
        let rowCount = (voices.count + 1) / 2
        let listHeight = CGFloat(rowCount) * Self.rowHeight
        let segmentHeight: CGFloat = 24
        let height = Self.inset + segmentHeight + 6 + listHeight + Self.inset
        setFrameSize(NSSize(width: Self.width, height: height))

        segments.frame = NSRect(x: Self.inset + 2, y: height - Self.inset - segmentHeight,
                                width: Self.width - Self.inset * 2 - 4, height: segmentHeight)
        let columnWidth = (Self.width - Self.inset * 2) / 2
        rows = voices.enumerated().map { index, voice in
            let column = CGFloat(index / rowCount)
            let row = CGFloat(index % rowCount)
            let frame = NSRect(x: Self.inset + column * columnWidth,
                               y: Self.inset + listHeight - (row + 1) * Self.rowHeight,
                               width: columnWidth, height: Self.rowHeight)
            let view = VoiceRow(frame: frame, voice: voice)
            view.isChecked = voice == selected
            view.onClick = { [weak self] voice in
                self?.setSelected(voice)
                self?.onSelect?(voice)
            }
            addSubview(view)
            return view
        }
        if let item = enclosingMenuItem { item.menu?.itemChanged(item) }
    }
}

/// One clickable voice name with a hover highlight, like a native menu item.
private final class VoiceRow: NSView {
    let voice: String
    var onClick: ((String) -> Void)?
    var isChecked = false { didSet { check.isHidden = !isChecked } }

    private let label = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var hovering = false { didSet { needsDisplay = true; updateColors() } }

    init(frame: NSRect, voice: String) {
        self.voice = voice
        super.init(frame: frame)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
        check.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        check.frame = NSRect(x: 6, y: (frame.height - 14) / 2, width: 14, height: 14)
        check.isHidden = true
        label.stringValue = Voices.displayName(voice)
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 24, y: (frame.height - 17) / 2, width: frame.width - 28, height: 17)
        addSubview(check)
        addSubview(label)
        updateColors()
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(Voices.displayName(voice))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
    }

    private func updateColors() {
        label.textColor = hovering ? .selectedMenuItemTextColor : .labelColor
        check.contentTintColor = hovering ? .selectedMenuItemTextColor : .controlAccentColor
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(voice) }
    }
}
