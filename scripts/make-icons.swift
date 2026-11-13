// Erzeugt die Dokument-Icons für Archivtypen im Stil der macOS-Dokumentsymbole:
// weißes Blatt mit Eselsohr, Reißverschluss von oben, Typ-Kürzel unten.
// Jeder Typ hat eine eigene Farbe (Reißverschluss + Kürzel).
//
//   swift scripts/make-icons.swift <ausgabe-ordner> [vorschau.png]
//
// Ergebnis: <ausgabe-ordner>/<typ>.icns (über iconutil) und optional ein Vorschaubild.
// Alles wird mit CoreGraphics gezeichnet, es werden keine Apple-Grafiken verwendet.

import AppKit

struct ArchiveType {
    let id: String
    let label: String
    let color: NSColor
}

let types = [
    ArchiveType(id: "zip", label: "ZIP", color: NSColor(srgbRed: 0.18, green: 0.48, blue: 0.96, alpha: 1)),   // Blau
    ArchiveType(id: "rar", label: "RAR", color: NSColor(srgbRed: 0.56, green: 0.29, blue: 0.85, alpha: 1)),   // Violett
    ArchiveType(id: "7z", label: "7Z", color: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.33, alpha: 1)),     // Grün
    ArchiveType(id: "tgz", label: "TGZ", color: NSColor(srgbRed: 0.93, green: 0.50, blue: 0.13, alpha: 1)),   // Orange
]

// Zeichenfläche in Einheiten von 1024, wird auf die Pixelgröße skaliert.
let left: CGFloat = 196, right: CGFloat = 828, bottom: CGFloat = 64, top: CGFloat = 960
let fold: CGFloat = 176, radius: CGFloat = 28

func pagePath() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: left + radius, y: bottom))
    path.line(to: NSPoint(x: right - radius, y: bottom))
    path.curve(to: NSPoint(x: right, y: bottom + radius),
               controlPoint1: NSPoint(x: right - radius / 2, y: bottom), controlPoint2: NSPoint(x: right, y: bottom + radius / 2))
    path.line(to: NSPoint(x: right, y: top - fold))
    path.line(to: NSPoint(x: right - fold, y: top))
    path.line(to: NSPoint(x: left + radius, y: top))
    path.curve(to: NSPoint(x: left, y: top - radius),
               controlPoint1: NSPoint(x: left + radius / 2, y: top), controlPoint2: NSPoint(x: left, y: top - radius / 2))
    path.line(to: NSPoint(x: left, y: bottom + radius))
    path.curve(to: NSPoint(x: left + radius, y: bottom),
               controlPoint1: NSPoint(x: left, y: bottom + radius / 2), controlPoint2: NSPoint(x: left + radius / 2, y: bottom))
    path.close()
    return path
}

func foldPath() -> NSBezierPath {
    let path = NSBezierPath()
    let r: CGFloat = 18
    path.move(to: NSPoint(x: right - fold, y: top))
    path.line(to: NSPoint(x: right - fold, y: top - fold + r))
    path.curve(to: NSPoint(x: right - fold + r, y: top - fold),
               controlPoint1: NSPoint(x: right - fold, y: top - fold + r / 2), controlPoint2: NSPoint(x: right - fold + r / 2, y: top - fold))
    path.line(to: NSPoint(x: right, y: top - fold))
    path.close()
    return path
}

func shade(_ color: NSColor, _ amount: CGFloat) -> NSColor {
    amount < 0 ? color.blended(withFraction: -amount, of: .black)! : color.blended(withFraction: amount, of: .white)!
}

func drawIcon(_ type: ArchiveType, pixels: Int) -> NSBitmapImageRep {
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

    let detailed = pixels >= 64          // Zähne und Kürzel erst ab 64 px
    let line = max(3, 1.2 / scale)       // mindestens ~1 Pixel Kontur

    // Blatt mit Schatten
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    pagePath().fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: .white, ending: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1))!
        .draw(in: pagePath(), angle: -90)
    NSColor(srgbRed: 0.76, green: 0.76, blue: 0.79, alpha: 1).setStroke()
    let outline = pagePath(); outline.lineWidth = line; outline.stroke()

    // Eselsohr
    NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.84, green: 0.84, blue: 0.87, alpha: 1))!
        .draw(in: foldPath(), angle: -45)
    let foldOutline = foldPath(); foldOutline.lineWidth = line; foldOutline.stroke()

    // Reißverschluss: Zähne abwechselnd links/rechts, von der Oberkante nach unten
    let center: CGFloat = 512
    let zipperTop = top - 4, zipperBottom: CGFloat = 520
    let color = type.color
    if detailed {
        let toothW: CGFloat = 46, toothH: CGFloat = 24, step: CGFloat = 30
        var y = zipperTop - toothH
        var leftSide = true
        while y > zipperBottom {
            let rect = NSRect(x: leftSide ? center - toothW + 4 : center - 4, y: y, width: toothW, height: toothH)
            let tooth = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSGradient(starting: shade(color, 0.25), ending: shade(color, -0.15))!.draw(in: tooth, angle: -90)
            shade(color, -0.35).setStroke(); tooth.lineWidth = 3; tooth.stroke()
            y -= step
            leftSide.toggle()
        }
    } else {
        let stripe = NSBezierPath(roundedRect: NSRect(x: center - 40, y: zipperBottom, width: 80, height: zipperTop - zipperBottom),
                                  xRadius: 10, yRadius: 10)
        color.setFill(); stripe.fill()
    }

    // Schieber und Zuglasche
    let slider = NSBezierPath(roundedRect: NSRect(x: center - 50, y: zipperBottom - 70, width: 100, height: 92),
                              xRadius: 22, yRadius: 22)
    NSGradient(starting: shade(color, 0.1), ending: shade(color, -0.3))!.draw(in: slider, angle: -90)
    shade(color, -0.45).setStroke(); slider.lineWidth = line; slider.stroke()

    let tab = NSBezierPath(roundedRect: NSRect(x: center - 32, y: zipperBottom - 200, width: 64, height: 150),
                           xRadius: 30, yRadius: 30)
    NSGradient(starting: shade(color, 0.05), ending: shade(color, -0.25))!.draw(in: tab, angle: -90)
    shade(color, -0.45).setStroke(); tab.lineWidth = line; tab.stroke()
    if detailed {
        let hole = NSBezierPath(roundedRect: NSRect(x: center - 13, y: zipperBottom - 175, width: 26, height: 56),
                                xRadius: 13, yRadius: 13)
        NSColor.white.withAlphaComponent(0.9).setFill(); hole.fill()
    }

    // Kürzel unten
    if detailed {
        let base = NSFont.systemFont(ofSize: type.label.count > 2 ? 150 : 170, weight: .heavy)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        let text = NSAttributedString(string: type.label, attributes: [.font: font, .foregroundColor: color, .kern: 4])
        let size = text.size()
        text.draw(at: NSPoint(x: center - size.width / 2, y: 112))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

// MARK: Ausgabe

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Aufruf: swift scripts/make-icons.swift <ausgabe-ordner> [vorschau.png]")
    exit(2)
}
let output = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let work = FileManager.default.temporaryDirectory.appendingPathComponent("zippy-icons-\(UUID().uuidString)")

for type in types {
    let iconset = work.appendingPathComponent("\(type.id).iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try png(drawIcon(type, pixels: points)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(drawIcon(type, pixels: points * 2)).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("\(type.id).icns").path]
    try iconutil.run()
    iconutil.waitUntilExit()
    print("\(type.id).icns")
}

// Vorschau: alle Typen nebeneinander in 256 px und darunter in 32 px
if args.count >= 3 {
    let big = 256, small = 32, gap = 24
    let width = types.count * (big + gap) + gap, height = big + small + 3 * gap
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (i, type) in types.enumerated() {
        let x = gap + i * (big + gap)
        // sourceOver, sonst überschreibt die transparente Fläche den Hintergrund
        drawIcon(type, pixels: big).draw(in: NSRect(x: x, y: small + 2 * gap, width: big, height: big),
                                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        drawIcon(type, pixels: small).draw(in: NSRect(x: x + (big - small) / 2, y: gap, width: small, height: small),
                                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(sheet).write(to: URL(fileURLWithPath: args[2]))
    print("Vorschau: \(args[2])")
}
try? FileManager.default.removeItem(at: work)
