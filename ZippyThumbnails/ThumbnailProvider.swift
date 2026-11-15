import AppKit
import ArchiveCore
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Finder thumbnails for ZIP and 7z: the usual type icon, with a lock if the archive is
/// password-protected.
///
/// Unprotected archives get the plain icon instead of a declined request: Finder keeps
/// the last thumbnail it got when a provider declines, so after removing a password the
/// lock would stay.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let locked = Self.isEncrypted(url)
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? .archive
        let icon = NSWorkspace.shared.icon(for: type)
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)

        let reply = QLThumbnailReply(contextSize: size, currentContextDrawing: {
            Self.draw(icon: icon, locked: locked, in: CGRect(origin: .zero, size: size))
            return true
        })
        Self.showAsPlainIcon(reply)
        handler(reply, nil)
    }

    /// Finder frames thumbnails like pictures (rounded tile, background). The reply's
    /// undocumented `iconFlavor` 0 means "plain" (as `kQLThumbnailIconPlainFlavor` did for
    /// the old Quick Look generators): our image is an icon and is shown as is.
    /// Without the property the thumbnail simply keeps the frame.
    private static func showAsPlainIcon(_ reply: QLThumbnailReply) {
        if reply.responds(to: NSSelectorFromString("setIconFlavor:")) {
            reply.setValue(0, forKey: "iconFlavor")
        }
    }

    /// 7z with encrypted file names can't even be listed without the password.
    static func isEncrypted(_ url: URL) -> Bool {
        do {
            let archive = try Archive(url: url)
            defer { archive.close() }
            return archive.needsPassword
        } catch ArchiveError.passwordRequired {
            return true
        } catch {
            return false
        }
    }

    /// The type icon, with a lock badge if `locked`.
    static func draw(icon: NSImage, locked: Bool, in rect: CGRect) {
        icon.draw(in: rect)
        guard locked else { return }

        // Top right, over the folded corner of document icons: keeps the type label free
        let badgeSide = rect.width * 0.30
        let badge = CGRect(x: rect.minX + rect.width * 0.78 - badgeSide / 2,
                           y: rect.minY + rect.height * 0.80 - badgeSide / 2,
                           width: badgeSide, height: badgeSide)
        let circle = NSBezierPath(ovalIn: badge)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = badgeSide * 0.08
        shadow.shadowOffset = CGSize(width: 0, height: -badgeSide * 0.03)
        shadow.set()
        NSColor.systemOrange.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = max(1, badgeSide * 0.05)
        circle.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: badgeSide * 0.5, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let lockSize = lock.size
            lock.draw(in: CGRect(x: badge.midX - lockSize.width / 2, y: badge.midY - lockSize.height / 2,
                                 width: lockSize.width, height: lockSize.height))
        }
    }
}
