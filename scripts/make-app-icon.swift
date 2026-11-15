// Generates Zippy's app icon in the style of macOS app icons (rounded square with
// a gradient), matching the document icons from make-icons.swift.
//
//   swift scripts/make-app-icon.swift <output.icns> [preview.png] [variant]
//
// Variants: "z" (default) – a large Z whose diagonal is a zipper;
//           "wort"        – a zipper from the top with the "zippy" wordmark below.
// The preview always shows both variants at 256 and 32 px.

import AppKit

let blue = NSColor(srgbRed: 0.18, green: 0.48, blue: 0.96, alpha: 1)   // same as the ZIP document icon

func shade(_ color: NSColor, _ amount: CGFloat) -> NSColor {
    amount < 0 ? color.blended(withFraction: -amount, of: .black)! : color.blended(withFraction: amount, of: .white)!
}

let paper = NSColor.white, paperShade = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1)
let outline = shade(blue, -0.45)

/// White surfaces (Z, band), like the paper of the document icons.
func fillPaper(_ path: NSBezierPath) {
    NSGradient(starting: paper, ending: paperShade)!.draw(in: path, angle: -90)
}

/// Teeth, slider and pull tab: blue with a dark outline, like the document icons.
func fillBlue(_ path: NSBezierPath, line: CGFloat, from: CGFloat = 0.25, to: CGFloat = -0.15) {
    NSGradient(starting: shade(blue, from), ending: shade(blue, to))!.draw(in: path, angle: -90)
    outline.setStroke(); path.lineWidth = line; path.stroke()
}

/// Zipper along the x axis of the current coordinate system, from 0 to `length`.
/// With `overrun` it extends that far past both ends, using whole teeth only, and ends in
/// stops like a real zipper; without it, it runs on and the caller clips it.
func zipper(length: CGFloat, detailed: Bool, line: CGFloat, overrun: CGFloat? = nil) {
    if detailed {
        let toothAlong: CGFloat = 24, toothAcross: CGFloat = 48, step: CGFloat = 30
        func tooth(at x: CGFloat, upper: Bool) {
            let rect = NSRect(x: x, y: upper ? -4 : 4 - toothAcross, width: toothAlong, height: toothAcross)
            fillBlue(NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7), line: 3)
        }
        if let overrun {
            let first = -overrun
            let count = Int((length + 2 * overrun - toothAlong) / step) + 1
            for i in 0..<count { tooth(at: first + CGFloat(i) * step, upper: i % 2 == 0) }
            // Stops: narrow clamps across both rows of teeth
            let lastEnd = first + CGFloat(count - 1) * step + toothAlong
            for x in [first - 16, lastEnd + 4] {
                let stop = NSRect(x: x, y: -toothAcross + 2, width: 12, height: 2 * toothAcross - 4)
                fillBlue(NSBezierPath(roundedRect: stop, xRadius: 5, yRadius: 5), line: 3, from: 0.0, to: -0.3)
            }
        } else {
            var x: CGFloat = -step
            var upper = true
            while x < length + step {
                tooth(at: x, upper: upper)
                x += step
                upper.toggle()
            }
        }
    } else {
        blue.setFill()
        let extra = overrun ?? 20
        NSBezierPath(rect: NSRect(x: -extra, y: -36, width: length + 2 * extra, height: 72)).fill()
    }
}

/// Slider on the zipper (rotated to `angle`) with a vertically hanging pull tab.
func slider(at point: NSPoint, angle: CGFloat, detailed: Bool, line: CGFloat) {
    // Pull tab first, so the slider covers its top
    if detailed {
        let tab = NSBezierPath(roundedRect: NSRect(x: point.x - 32, y: point.y - 175, width: 64, height: 150),
                               xRadius: 30, yRadius: 30)
        fillBlue(tab, line: line, from: 0.05, to: -0.25)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 13, y: point.y - 150, width: 26, height: 56),
                     xRadius: 13, yRadius: 13).fill()
    }
    rotated(at: point, by: angle) {
        fillBlue(NSBezierPath(roundedRect: NSRect(x: -46, y: -56, width: 92, height: 112), xRadius: 22, yRadius: 22),
                 line: line, from: 0.1, to: -0.3)
    }
}

/// Draws in a translated and rotated coordinate system.
func rotated(at point: NSPoint, by angle: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: point.x, yBy: point.y)
    t.rotate(byRadians: angle)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

/// Closed path through the corners, each corner rounded with its own radius.
func roundedPolygon(_ corners: [(NSPoint, CGFloat)]) -> NSBezierPath {
    let path = NSBezierPath()
    let first = corners[0].0, last = corners[corners.count - 1].0
    path.move(to: NSPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
    for (index, corner) in corners.enumerated() {
        let next = corners[(index + 1) % corners.count].0
        path.appendArc(from: corner.0, to: next, radius: corner.1)
    }
    path.close()
    return path
}

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func drawAppIcon(variant: String, pixels: Int) -> NSBitmapImageRep {
    let rep = bitmap(width: pixels, height: pixels)
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let detailed = pixels >= 64
    let line = max(4, 1.2 / scale)

    // Base shape on the macOS icon grid: 824 × 824, centered, with a shadow.
    // Darker blue than the zipper so the zipper stands out.
    let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    blue.setFill(); squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: shade(blue, -0.05), ending: shade(blue, -0.5))!.draw(in: squircle, angle: -90)
    squircle.addClip()

    switch variant {
    case "wort":
        // White band with a zipper from the top, wordmark below
        let band = NSBezierPath(roundedRect: NSRect(x: 512 - 62, y: 560, width: 124, height: 420), xRadius: 20, yRadius: 20)
        fillPaper(band)
        NSGraphicsContext.saveGraphicsState()
        band.addClip()
        rotated(at: NSPoint(x: 512, y: 560), by: .pi / 2) { zipper(length: 420, detailed: detailed, line: line) }
        NSGraphicsContext.restoreGraphicsState()
        slider(at: NSPoint(x: 512, y: 590), angle: .pi / 2, detailed: detailed, line: line)
        if detailed {
            let base = NSFont.systemFont(ofSize: 200, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 200) } ?? base
            let text = NSAttributedString(string: "zippy", attributes: [.font: font, .foregroundColor: paper])
            let size = text.size()
            text.draw(at: NSPoint(x: 512 - size.width / 2, y: 150))
        }

    default:
        // White Z with the zipper running along its diagonal
        let left: CGFloat = 250, right: CGFloat = 774, barHeight: CGFloat = 112, stroke: CGFloat = 190
        let topBar = NSRect(x: left, y: 674, width: right - left, height: barHeight)
        let bottomBar = NSRect(x: left, y: 238, width: right - left, height: barHeight)
        // The Z as a single shape: bars and diagonal blend into each other with curves
        // (wide fillets inside, gentle arcs outside) instead of meeting at sharp corners.
        let z = roundedPolygon([
            (NSPoint(x: left, y: topBar.maxY), 28),                     // top left
            (NSPoint(x: right, y: topBar.maxY), 28),                    // top right
            (NSPoint(x: right, y: topBar.minY), 60),                    // into the diagonal (outside)
            (NSPoint(x: left + stroke, y: bottomBar.maxY), 10),         // bottom fillet
            (NSPoint(x: right, y: bottomBar.maxY), 28),
            (NSPoint(x: right, y: bottomBar.minY), 28),                 // bottom right
            (NSPoint(x: left, y: bottomBar.minY), 28),                  // bottom left
            (NSPoint(x: left, y: bottomBar.maxY), 60),                  // into the diagonal (outside)
            (NSPoint(x: right - stroke, y: topBar.minY), 10),           // top fillet
            (NSPoint(x: left, y: topBar.minY), 28),
        ])
        NSGraphicsContext.saveGraphicsState()
        let zShadow = NSShadow()
        zShadow.shadowColor = NSColor(white: 0, alpha: 0.25)
        zShadow.shadowBlurRadius = 14
        zShadow.shadowOffset = NSSize(width: 0, height: -6)
        zShadow.set()
        paper.setFill(); z.fill()
        NSGraphicsContext.restoreGraphicsState()
        fillPaper(z)

        let start = NSPoint(x: left + stroke / 2, y: bottomBar.maxY)
        let end = NSPoint(x: right - stroke / 2, y: topBar.minY)
        let angle = atan2(end.y - start.y, end.x - start.x)
        // The zipper runs a little into the bars and ends there with stops;
        // clipped to the whole Z, not just the diagonal
        NSGraphicsContext.saveGraphicsState()
        z.addClip()
        rotated(at: start, by: angle) {
            zipper(length: hypot(end.x - start.x, end.y - start.y), detailed: detailed, line: line, overrun: 24)
        }
        NSGraphicsContext.restoreGraphicsState()
        let s: CGFloat = 0.62
        slider(at: NSPoint(x: start.x + (end.x - start.x) * s, y: start.y + (end.y - start.y) * s),
               angle: angle, detailed: detailed, line: line)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

// MARK: Output

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift scripts/make-app-icon.swift <output.icns> [preview.png] [z|wort]")
    exit(2)
}
let variant = args.count >= 4 ? args[3] : "z"
let output = URL(fileURLWithPath: args[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("zippy-app-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(drawAppIcon(variant: variant, pixels: points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(drawAppIcon(variant: variant, pixels: points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("\(output.lastPathComponent) (\(variant))")

if args.count >= 3 {
    let variants = ["z", "wort"]
    let big = 256, small = 32, gap = 24
    let width = variants.count * (big + gap) + gap, height = big + small + 3 * gap
    let sheet = bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (i, v) in variants.enumerated() {
        let x = gap + i * (big + gap)
        drawAppIcon(variant: v, pixels: big).draw(in: NSRect(x: x, y: small + 2 * gap, width: big, height: big),
                                                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        drawAppIcon(variant: v, pixels: small).draw(in: NSRect(x: x + (big - small) / 2, y: gap, width: small, height: small),
                                                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(sheet).write(to: URL(fileURLWithPath: args[2]))
    print("Preview: \(args[2])")
}
