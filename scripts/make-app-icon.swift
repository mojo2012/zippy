// Erzeugt das App-Icon von Zippy im Stil der macOS-App-Icons (abgerundetes
// Quadrat mit Verlauf), passend zu den Dokument-Icons aus make-icons.swift.
//
//   swift scripts/make-app-icon.swift <ausgabe.icns> [vorschau.png] [variante]
//
// Varianten: "z" (Standard) – großes Z, dessen Diagonale ein Reißverschluss ist;
//            "wort"         – Reißverschluss von oben, darunter der Schriftzug "zippy".
// Die Vorschau zeigt immer beide Varianten in 256 und 32 px.

import AppKit

let blue = NSColor(srgbRed: 0.18, green: 0.48, blue: 0.96, alpha: 1)   // wie das ZIP-Icon

func shade(_ color: NSColor, _ amount: CGFloat) -> NSColor {
    amount < 0 ? color.blended(withFraction: -amount, of: .black)! : color.blended(withFraction: amount, of: .white)!
}

let paper = NSColor.white, paperShade = NSColor(srgbRed: 0.90, green: 0.92, blue: 0.96, alpha: 1)
let outline = shade(blue, -0.45)

/// Weiße Flächen (Z, Band) wie das Blatt der Dokument-Icons.
func fillPaper(_ path: NSBezierPath) {
    NSGradient(starting: paper, ending: paperShade)!.draw(in: path, angle: -90)
}

/// Zahn, Schieber, Lasche in Blau mit dunkler Kontur, wie bei den Dokument-Icons.
func fillBlue(_ path: NSBezierPath, line: CGFloat, from: CGFloat = 0.25, to: CGFloat = -0.15) {
    NSGradient(starting: shade(blue, from), ending: shade(blue, to))!.draw(in: path, angle: -90)
    outline.setStroke(); path.lineWidth = line; path.stroke()
}

/// Reißverschluss entlang der x-Achse des aktuellen Koordinatensystems, von 0 bis `length`.
func zipper(length: CGFloat, detailed: Bool, line: CGFloat) {
    if detailed {
        let toothAlong: CGFloat = 24, toothAcross: CGFloat = 48, step: CGFloat = 30
        var x: CGFloat = -step
        var upper = true
        while x < length + step {
            let rect = NSRect(x: x, y: upper ? -4 : 4 - toothAcross, width: toothAlong, height: toothAcross)
            fillBlue(NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7), line: 3)
            x += step
            upper.toggle()
        }
    } else {
        blue.setFill()
        NSBezierPath(rect: NSRect(x: -20, y: -36, width: length + 40, height: 72)).fill()
    }
}

/// Schieber auf dem Reißverschluss (im gedrehten System) und senkrecht hängende Lasche.
func slider(at point: NSPoint, angle: CGFloat, detailed: Bool, line: CGFloat) {
    // Lasche zuerst, damit der Schieber sie oben verdeckt
    if detailed {
        let tab = NSBezierPath(roundedRect: NSRect(x: point.x - 32, y: point.y - 175, width: 64, height: 150),
                               xRadius: 30, yRadius: 30)
        fillBlue(tab, line: line, from: 0.05, to: -0.25)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: point.x - 13, y: point.y - 150, width: 26, height: 56),
                     xRadius: 13, yRadius: 13).fill()
    }
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: point.x, yBy: point.y)
    t.rotate(byRadians: angle)
    t.concat()
    fillBlue(NSBezierPath(roundedRect: NSRect(x: -46, y: -56, width: 92, height: 112), xRadius: 22, yRadius: 22),
             line: line, from: 0.1, to: -0.3)
    NSGraphicsContext.restoreGraphicsState()
}

/// Zeichnet in einem verschobenen und gedrehten Koordinatensystem.
func rotated(at point: NSPoint, by angle: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: point.x, yBy: point.y)
    t.rotate(byRadians: angle)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawAppIcon(variant: String, pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let detailed = pixels >= 64
    let line = max(4, 1.2 / scale)

    // Grundform nach dem macOS-Raster: 824 × 824 mittig, mit Schatten.
    // Dunkleres Blau als der Reißverschluss, damit er sich abhebt.
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
        // Weißes Band mit Reißverschluss von oben, Schriftzug darunter
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
        // Weißes Z, in dessen Diagonale der Reißverschluss läuft
        let left: CGFloat = 250, right: CGFloat = 774, barHeight: CGFloat = 112, stroke: CGFloat = 190
        let topBar = NSRect(x: left, y: 674, width: right - left, height: barHeight)
        let bottomBar = NSRect(x: left, y: 238, width: right - left, height: barHeight)
        let diagonal = NSBezierPath()
        diagonal.move(to: NSPoint(x: left, y: bottomBar.maxY - 1))
        diagonal.line(to: NSPoint(x: left + stroke, y: bottomBar.maxY - 1))
        diagonal.line(to: NSPoint(x: right, y: topBar.minY + 1))
        diagonal.line(to: NSPoint(x: right - stroke, y: topBar.minY + 1))
        diagonal.close()
        let z = NSBezierPath(roundedRect: topBar, xRadius: 28, yRadius: 28)
        z.append(NSBezierPath(roundedRect: bottomBar, xRadius: 28, yRadius: 28))
        z.append(diagonal)
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
        NSGraphicsContext.saveGraphicsState()
        diagonal.addClip()
        rotated(at: start, by: angle) {
            zipper(length: hypot(end.x - start.x, end.y - start.y), detailed: detailed, line: line)
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

// MARK: Ausgabe

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Aufruf: swift scripts/make-app-icon.swift <ausgabe.icns> [vorschau.png] [z|wort]")
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
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
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
    print("Vorschau: \(args[2])")
}
