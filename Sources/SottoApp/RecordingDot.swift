import AppKit

/// The menu bar icon while recording: a red dot inside a faint ring that swells with the volume.
enum RecordingDot {
    static let steps = 8
    private static let images: [NSImage] = (0...steps).map(draw)

    /// Turns a smoothed volume (0...1) into the matching picture.
    static func image(for pulse: Float) -> NSImage {
        // Speech peaks sit well below full scale, so lift the quiet end.
        let lifted = min(1, max(0, pulse).squareRoot() * 1.4)
        return images[Int((lifted * Float(steps)).rounded())]
    }

    static func draw(step: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            func circle(_ radius: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            let ring = circle(7.5)
            ring.lineWidth = 1
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            ring.stroke()
            NSColor.systemRed.setFill()
            circle(3 + 4.5 * CGFloat(step) / CGFloat(steps)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
