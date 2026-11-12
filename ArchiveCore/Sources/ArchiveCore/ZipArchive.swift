import CArchive
import Foundation

public enum ArchiveError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case notFound
    case notAFile
    case encrypted
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let reason): "Archiv lässt sich nicht öffnen: \(reason)"
        case .notFound: "Eintrag nicht gefunden."
        case .notAFile: "Eintrag ist keine Datei."
        case .encrypted: "Eintrag ist verschlüsselt."
        case .readFailed(let reason): "Lesen fehlgeschlagen: \(reason)"
        }
    }
}

/// Ein geöffnetes ZIP-Archiv: Index plus Lesezugriff auf Dateien.
///
/// Lesen: Beim ersten Zugriff wird die Datei vollständig in einen Cache-Ordner
/// entpackt, danach wird von dort gelesen. So sind beliebige Offsets möglich,
/// auch wenn der Eintrag komprimiert ist. Der Cache wird bei ``close()`` gelöscht.
///
/// Thread-sicher: Entpacken passiert nacheinander, Lesen aus dem Cache parallel.
public final class ZipArchive: @unchecked Sendable {
    public let url: URL
    public let index: ArchiveIndex

    private let cacheDirectory: URL
    private let lock = NSLock()
    private var extracted: [UInt64: URL] = [:]

    public init(url: URL) throws {
        self.url = url
        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        self.index = try Self.buildIndex(url: url, rootDate: fileDate)
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { close() }

    /// Löscht den Cache. Danach entpackt ``read(_:offset:length:)`` bei Bedarf neu.
    public func close() {
        lock.withLock {
            extracted.removeAll()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    /// Liest bis zu `length` Bytes ab `offset`. Am Dateiende kommen weniger zurück.
    public func read(_ id: UInt64, offset: UInt64, length: Int) throws -> Data {
        guard let entry = index.entry(id) else { throw ArchiveError.notFound }
        guard entry.kind == .file else { throw ArchiveError.notAFile }
        guard offset < entry.size, length > 0 else { return Data() }

        let file = try extractedFile(for: entry)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    /// Liest eine ganze Datei. Praktisch für kleine Dateien und Tests.
    public func contents(of id: UInt64) throws -> Data {
        guard let entry = index.entry(id) else { throw ArchiveError.notFound }
        return try read(id, offset: 0, length: Int(entry.size))
    }

    // MARK: Entpacken

    private func extractedFile(for entry: ArchiveEntry) throws -> URL {
        try lock.withLock {
            if let file = extracted[entry.id] { return file }
            guard !entry.isEncrypted else { throw ArchiveError.encrypted }
            guard let position = entry.archiveIndex else { throw ArchiveError.notAFile }

            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let file = cacheDirectory.appendingPathComponent(String(entry.id))
            try extract(position: position, to: file)
            extracted[entry.id] = file
            return file
        }
    }

    private func extract(position: Int, to file: URL) throws {
        let archive = try Self.openArchive(url)
        defer { archive_read_free(archive) }

        var header: OpaquePointer?
        for _ in 0..<position {
            guard archive_read_next_header(archive, &header) == ARCHIVE_OK else {
                throw ArchiveError.readFailed(Self.message(archive))
            }
            archive_read_data_skip(archive)
        }
        guard archive_read_next_header(archive, &header) == ARCHIVE_OK else {
            throw ArchiveError.readFailed(Self.message(archive))
        }

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ArchiveError.readFailed("Cache-Datei lässt sich nicht anlegen")
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }

        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                archive_read_data(archive, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                try? FileManager.default.removeItem(at: file)
                throw ArchiveError.readFailed(Self.message(archive))
            }
            try output.write(contentsOf: buffer[0..<count])
        }
    }

    // MARK: Index aufbauen

    private static let typeMask: UInt32 = 0o170000
    private static let typeDirectory: UInt32 = 0o040000
    private static let typeSymlink: UInt32 = 0o120000

    private static func buildIndex(url: URL, rootDate: Date) throws -> ArchiveIndex {
        let archive = try openArchive(url)
        defer { archive_read_free(archive) }

        var index = ArchiveIndex(rootDate: rootDate)
        var header: OpaquePointer?
        var position = 0
        while true {
            let status = archive_read_next_header(archive, &header)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let header else {
                throw ArchiveError.openFailed(message(archive))
            }
            defer {
                archive_read_data_skip(archive)
                position += 1
            }

            guard let rawPath = archive_entry_pathname_utf8(header) ?? archive_entry_pathname(header),
                  let components = ArchiveIndex.sanitize(String(cString: rawPath)) else {
                continue   // leerer oder unsicherer Pfad (z. B. "../")
            }

            let type = UInt32(archive_entry_filetype(header)) & typeMask
            let kind: ArchiveEntry.Kind = switch type {
            case typeDirectory: .directory
            case typeSymlink: .symlink
            default: .file
            }

            var permissions = UInt16(archive_entry_perm(header) & 0o777)
            if permissions == 0 { permissions = kind == .directory ? 0o755 : 0o644 }
            permissions |= kind == .directory ? 0o500 : 0o400   // Besitzer darf immer lesen

            let date = archive_entry_mtime_is_set(header) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(header))
                       + TimeInterval(archive_entry_mtime_nsec(header)) / 1e9)
                : rootDate

            var target: String?
            if kind == .symlink {
                let raw = archive_entry_symlink_utf8(header) ?? archive_entry_symlink(header)
                target = raw.map { String(cString: $0) }
            }

            index.insert(path: components, kind: kind, size: UInt64(max(0, archive_entry_size(header))),
                         modificationDate: date, permissions: permissions, symlinkTarget: target,
                         isEncrypted: archive_entry_is_encrypted(header) != 0, archiveIndex: position)
        }
        return index
    }

    // MARK: libarchive

    private static func openArchive(_ url: URL) throws -> OpaquePointer {
        guard let archive = archive_read_new() else { throw ArchiveError.openFailed("libarchive") }
        archive_read_support_format_zip(archive)
        guard archive_read_open_filename(archive, url.path, 64 * 1024) == ARCHIVE_OK else {
            let reason = message(archive)
            archive_read_free(archive)
            throw ArchiveError.openFailed(reason)
        }
        return archive
    }

    private static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unbekannter Fehler"
    }
}
