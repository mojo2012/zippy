import CArchive
import Foundation

public enum ArchiveError: Error, Equatable, LocalizedError {
    case openFailed(String)
    case notFound
    case notAFile
    case passwordRequired
    case wrongPassword
    case readFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let reason): String(localized: "The archive can’t be opened: \(reason)", bundle: .module)
        case .notFound: String(localized: "Entry not found.", bundle: .module)
        case .notAFile: String(localized: "Entry is not a file.", bundle: .module)
        case .passwordRequired: String(localized: "The archive is password-protected.", bundle: .module)
        case .wrongPassword: String(localized: "The password is wrong.", bundle: .module)
        case .readFailed(let reason): String(localized: "Reading failed: \(reason)", bundle: .module)
        case .writeFailed(let reason): String(localized: "Saving failed: \(reason)", bundle: .module)
        }
    }
}

/// An open archive (ZIP, TAR, 7z, RAR, or an SQLite database shown as files): the index plus read access to its files.
///
/// Reading: on first access a file is extracted completely into a cache directory and
/// read from there afterwards. That allows arbitrary offsets even for compressed entries.
/// The cache is deleted by ``close()``. For compressed TARs, extracting means reading
/// from the start up to the file.
///
/// Thread-safe: extraction is serialized, reads from the cache run in parallel.
public final class Archive: @unchecked Sendable {
    public let source: any ArchiveSource
    /// All parts of a split archive; empty otherwise.
    public private(set) var parts: [URL] = []
    public let index: ArchiveIndex
    public let format: ArchiveFormat
    /// Password for encrypted entries (ZipCrypto or AES).
    public let password: String?

    /// Whether the archive contains encrypted files. ZIP never encrypts names, so listing
    /// always works. 7z can encrypt names too, in which case opening without a password
    /// already throws ``ArchiveError/passwordRequired``. TAR has no encryption.
    public var needsPassword: Bool {
        index.entries.values.contains { $0.isEncrypted && $0.kind == .file }
    }

    /// Whether Zippy can save changes: the format must be writable (and able to keep the
    /// encryption, if there is any), and the archive must not be split (the parts would have
    /// to be re-split).
    public var canSave: Bool {
        let handler = format.handler
        return handler.isWritable && parts.isEmpty && (!needsPassword || handler.canSaveEncrypted)
    }

    /// Whether Zippy can set or change a password (ZIP, AES-256).
    public var canSetPassword: Bool { format.handler.canSetPassword && parts.isEmpty }

    /// Whether Zippy can decrypt the archive and save it without a password (ZIP, 7z).
    public var canRemovePassword: Bool {
        format.handler.canRemovePassword && parts.isEmpty && needsPassword
    }

    /// Lists the entries and extracts them: libarchive, or SQLite for databases.
    private let reader: any EntryReader
    private let cacheDirectory: URL
    private let lock = NSLock()
    private var extracted: [UInt64: URL] = [:]

    /// Opens the archive at `url`, including all parts of a split archive.
    public convenience init(url: URL, password: String? = nil) throws {
        let fileDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let parts = try ArchiveParts.parts(for: url) ?? []
        do {
            let source: any ArchiveSource = parts.count > 1 ? try MultiPartSource(urls: parts)
                                                            : try FileSource(url: parts.first ?? url)
            try self.init(source: source, date: fileDate, password: password)
            if parts.count > 1 { self.parts = parts }
        } catch ArchiveError.openFailed(let reason) where Self.isSplitZip(url) {
            // libarchive only reads this one file and then reports something like
            // "Too small block encountered", which means nothing to people.
            throw ArchiveError.openFailed(String(localized: "split ZIPs (.z01 …) aren’t supported yet (\(reason))", bundle: .module))
        }
    }

    /// A part of an Info-ZIP/WinZip split ZIP ("x.z01" … "x.zip"). Unlike `.zip.001`,
    /// these aren't plain byte slices.
    static func isSplitZip(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().range(of: #"\.z\d\d$"#, options: .regularExpression) != nil
    }

    /// Opens an archive from any source, e.g. a block device.
    /// `date` is used for directories without a date of their own.
    public init(source: any ArchiveSource, date: Date = Date(), password: String? = nil) throws {
        self.source = source
        self.password = password
        let reader: any EntryReader = try SQLiteEntryReader.canRead(source)
            ? SQLiteEntryReader(source: source, rootDate: date)
            : LibarchiveEntryReader(source: source, rootDate: date, password: password)
        self.reader = reader
        self.index = reader.index
        self.format = reader.format
        // libarchive detects encrypted RAR data but can't decrypt it
        if !format.handler.canDecrypt, index.entries.values.contains(where: { $0.isEncrypted }) {
            throw ArchiveError.openFailed(Self.encryptedUnsupported(format))
        }
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { close() }

    /// Volume name: the file name without extension, without both for "x.tar.gz".
    /// For split archives also without the part suffix: "Photos.part01.rar", "Photos.7z.001" → "Photos".
    public static func volumeName(for url: URL) -> String {
        let name = ArchiveParts.wholeName(of: url) ?? url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return (stem as NSString).pathExtension.lowercased() == "tar" ? (stem as NSString).deletingPathExtension : stem
    }

    /// Deletes the cache. ``read(_:offset:length:)`` extracts again when needed.
    public func close() {
        lock.withLock {
            extracted.removeAll()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    /// Checks the password by extracting the smallest encrypted file.
    /// Throws ``ArchiveError/passwordRequired`` or ``ArchiveError/wrongPassword``.
    public func checkPassword() throws {
        let candidates = index.entries.values.filter { $0.isEncrypted && $0.kind == .file && $0.size > 0 }
        guard let smallest = candidates.min(by: { $0.size < $1.size }) else { return }
        _ = try read(smallest.id, offset: 0, length: 1)
    }

    /// Reads up to `length` bytes from `offset`. Returns fewer at the end of the file.
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

    /// Reads a whole file. Handy for small files and tests.
    public func contents(of id: UInt64) throws -> Data {
        guard let entry = index.entry(id) else { throw ArchiveError.notFound }
        return try read(id, offset: 0, length: Int(entry.size))
    }

    // MARK: Extraction

    private func extractedFile(for entry: ArchiveEntry) throws -> URL {
        try lock.withLock {
            if let file = extracted[entry.id] { return file }
            guard !entry.isEncrypted || password != nil else { throw ArchiveError.passwordRequired }
            guard let position = entry.archiveIndex else { throw ArchiveError.notAFile }

            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let file = cacheDirectory.appendingPathComponent(String(entry.id))
            do {
                try reader.extract(position: position, to: file)
            } catch ArchiveError.readFailed where entry.isEncrypted && !format.handler.verifiesPassword {
                throw ArchiveError.wrongPassword
            }
            extracted[entry.id] = file
            return file
        }
    }

}
