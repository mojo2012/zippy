// Generates the document icons for archive types in the style of macOS document icons:
// a white page with a folded corner, a zipper from the top and the type label at the bottom.
// Each type has its own color (zipper + label).
//
//   swift scripts/make-icons.swift <output-folder> [preview.png]
//
// Result: <output-folder>/<type>.icns (via iconutil) and optionally a preview image.
// Everything is drawn in code; no Apple artwork is used.

import AppKit

struct ArchiveType {
    let id: String
    let label: String
    let color: NSColor
}

let types = [
    ArchiveType(id: "zip", label: "ZIP", color: NSColor(srgbRed: 0.18, green: 0.48, blue: 0.96, alpha: 1)),   // blue
    ArchiveType(id: "rar", label: "RAR", color: NSColor(srgbRed: 0.56, green: 0.29, blue: 0.85, alpha: 1)),   // purple
    ArchiveType(id: "7z", label: "7Z", color: NSColor(srgbRed: 0.18, green: 0.62, blue: 0.33, alpha: 1)),     // green
    ArchiveType(id: "tgz", label: "TGZ", color: NSColor(srgbRed: 0.93, green: 0.50, blue: 0.13, alpha: 1)),   // orange
]

// Canvas in units of 1024, scaled to the pixel size.
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

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func drawIcon(_ type: ArchiveType, pixels: Int) -> NSBitmapImageRep {
    let rep = bitmap(width: pixels, height: pixels)
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let detailed = pixels >= 64          // teeth and label from 64 px up
    let line = max(3, 1.2 / scale)       // outline at least ~1 pixel

    // Page with shadow
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    // NSShadow ignores the current transform: scale by hand, otherwise small sizes get a
    // 22-pixel halo
    shadow.shadowBlurRadius = 22 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    NSColor.white.setFill()
    pagePath().fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: .white, ending: NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1))!
        .draw(in: pagePath(), angle: -90)
    NSColor(srgbRed: 0.76, green: 0.76, blue: 0.79, alpha: 1).setStroke()
    let outline = pagePath(); outline.lineWidth = line; outline.stroke()

    // Folded corner
    NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
               ending: NSColor(srgbRed: 0.84, green: 0.84, blue: 0.87, alpha: 1))!
        .draw(in: foldPath(), angle: -45)
    let foldOutline = foldPath(); foldOutline.lineWidth = line; foldOutline.stroke()

    // Zipper: teeth alternating left/right, from the top edge down
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

    // Slider and pull tab
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

    // Type label at the bottom
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

// MARK: Output

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift scripts/make-icons.swift <output-folder> [preview.png]")
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

// Preview: all types side by side at 256 px, with 32 px versions below
if args.count >= 3 {
    let big = 256, small = 32, gap = 24
    let width = types.count * (big + gap) + gap, height = big + small + 3 * gap
    let sheet = bitmap(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (i, type) in types.enumerated() {
        let x = gap + i * (big + gap)
        // sourceOver, otherwise the transparent area overwrites the background
        drawIcon(type, pixels: big).draw(in: NSRect(x: x, y: small + 2 * gap, width: big, height: big),
                                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        drawIcon(type, pixels: small).draw(in: NSRect(x: x + (big - small) / 2, y: gap, width: small, height: small),
                                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    try png(sheet).write(to: URL(fileURLWithPath: args[2]))
    print("Preview: \(args[2])")
}
try? FileManager.default.removeItem(at: work)
