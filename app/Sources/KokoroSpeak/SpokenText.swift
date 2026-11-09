import AppKit

/// Shared drawing for the text being spoken (mini player and menu header)
/// and the animated wave icon.
enum SpokenText {
    static func highlightColor(_ highlight: Settings.Highlight) -> NSColor {
        switch highlight {
        case .yellow: return NSColor.systemYellow.withAlphaComponent(0.45)
        case .blue: return NSColor.systemTeal.withAlphaComponent(0.35)
        }
    }

    /// The current chunk of text, trimmed to about `maxLength` characters around
    /// the current word. Spoken words are dimmed and the current word is highlighted.
    static func attributed(_ snapshot: Speaker.Snapshot, maxLength: Int, font: NSFont,
                           highlight: Settings.Highlight) -> NSAttributedString {
        let text = snapshot.text
        let chunk = NSIntersectionRange(snapshot.chunkRange, NSRange(location: 0, length: text.length))
        guard chunk.length > 0 else { return NSAttributedString(string: "") }

        var window = chunk
        if chunk.length > maxLength {
            let anchor = snapshot.wordRange?.location ?? chunk.location
            var start = max(chunk.location, anchor - maxLength / 3)
            start = min(start, NSMaxRange(chunk) - maxLength)
            if start > chunk.location {
                let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: [],
                                                  range: NSRange(location: start, length: NSMaxRange(chunk) - start))
                if space.location != NSNotFound, space.location < anchor { start = space.location + 1 }
            }
            var end = min(NSMaxRange(chunk), start + maxLength)
            if end < NSMaxRange(chunk) {
                let space = text.rangeOfCharacter(from: .whitespacesAndNewlines, options: .backwards,
                                                  range: NSRange(location: start, length: end - start))
                if space.location != NSNotFound, space.location > anchor { end = space.location }
            }
            window = NSRange(location: start, length: end - start)
        }

        let visible = (text.substring(with: window) as NSString)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let result = NSMutableAttributedString(string: visible, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        if let word = snapshot.wordRange {
            let local = NSRange(location: word.location - window.location, length: word.length)
            let whole = NSRange(location: 0, length: result.length)
            let current = NSIntersectionRange(local, whole)
            if current.length > 0 {
                result.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                    range: NSRange(location: 0, length: current.location))
                result.addAttribute(.backgroundColor, value: highlightColor(highlight), range: current)
            }
        }
        if window.location > chunk.location { result.insert(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]), at: 0) }
        if NSMaxRange(window) < NSMaxRange(chunk) { result.append(NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
        return result
    }

    static func timeLeft(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        let total = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d left", total / 60, total % 60)
    }

    /// A small sine wave. `phase` animates it; `amplitude` 0...1.
    static func waveImage(size: CGFloat, phase: CGFloat, amplitude: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath()
            let mid = rect.midY
            let height = rect.height * 0.32 * amplitude
            let steps = 28
            for step in 0...steps {
                let x = rect.minX + 1.5 + (rect.width - 3) * CGFloat(step) / CGFloat(steps)
                let t = CGFloat(step) / CGFloat(steps)
                // Taper the ends so it reads as a voice wave.
                let envelope = sin(.pi * t)
                let y = mid + height * envelope * sin(2 * .pi * 1.5 * t + phase)
                step == 0 ? path.move(to: NSPoint(x: x, y: y)) : path.line(to: NSPoint(x: x, y: y))
            }
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
            return true
        }
    }
}
