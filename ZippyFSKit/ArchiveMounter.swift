import AppKit

/// Sequoia-Weg: macOS 15 kann FSKit-Volumes nur aus Block-Geräten bauen.
/// Darum wird das ZIP als rohes Disk-Image angehängt:
///  1. APFS-Clone des ZIPs anlegen (kostet keinen Platz, Original bleibt unberührt)
///  2. auf ein Vielfaches von 512 Byte auffüllen, sonst schneidet macOS das Ende
///     und damit das ZIP-Inhaltsverzeichnis ab
///  3. an DiskImageMounter übergeben; die FSKit-Erweiterung erkennt das ZIP
enum ArchiveMounter {
    static let diskImageMounter = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")

    static func mount(zip: URL) async throws {
        let image = try makePaddedClone(of: zip)
        let config = NSWorkspace.OpenConfiguration()
        _ = try await NSWorkspace.shared.open([image], withApplicationAt: diskImageMounter, configuration: config)
    }

    static func makePaddedClone(of zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = dir.appendingPathComponent(zip.deletingPathExtension().lastPathComponent + ".img")
        try? FileManager.default.removeItem(at: image)

        let accessing = zip.startAccessingSecurityScopedResource()
        defer { if accessing { zip.stopAccessingSecurityScopedResource() } }

        // copyItem nutzt auf APFS automatisch clonefile()
        try FileManager.default.copyItem(at: zip, to: image)

        let handle = try FileHandle(forWritingTo: image)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let padding = (512 - Int(size % 512)) % 512
        if padding > 0 { try handle.write(contentsOf: Data(count: padding)) }
        return image
    }
}
