// Draws the Sotto icon: a soft waveform on a dark rounded square.
// Usage: swift scripts/make-icon.swift packaging
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func render(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(red: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(red: 0.18, green: 0.22, blue: 0.36, alpha: 1)])!
        .draw(in: shape, angle: -90)

    // Seven bars, tallest in the middle, like a quiet voice.
    let heights: [CGFloat] = [0.16, 0.30, 0.46, 0.60, 0.46, 0.30, 0.16]
    let barWidth = rect.width * 0.075
    let gap = rect.width * 0.045
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2
    for (i, h) in heights.enumerated() {
        let height = rect.height * h
        let bar = NSRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
        let t = CGFloat(i) / CGFloat(heights.count - 1)
        NSColor(red: 0.55 + 0.35 * t, green: 0.80 - 0.15 * t, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let iconset = "\(outDir)/Sotto.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    save(render(base), "\(iconset)/icon_\(base)x\(base).png")
    save(render(base * 2), "\(iconset)/icon_\(base)x\(base)@2x.png")
}
save(render(512), "\(outDir)/icon.png")
print("wrote \(iconset) and \(outDir)/icon.png")
