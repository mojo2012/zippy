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

/// An open archive (ZIP, TAR, 7z or RAR): the index plus read access to its files.
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
        (self.index, self.format) = try Self.buildIndex(source: source, rootDate: date, password: password)
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
                try extract(position: position, to: file)
            } catch ArchiveError.readFailed where entry.isEncrypted && !format.handler.verifiesPassword {
                throw ArchiveError.wrongPassword
            }
            extracted[entry.id] = file
            return file
        }
    }

    private func extract(position: Int, to file: URL) throws {
        let reader = try ArchiveReader(source: source, password: password)
        let archive = reader.archive
        defer { reader.close() }

        for _ in 0..<position {
            try reader.nextHeader()
            archive_read_data_skip(archive)
        }
        try reader.nextHeader()

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ArchiveError.readFailed(String(localized: "can’t create the cache file", bundle: .module))
        }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }

        var buffer = [UInt8](repeating: 0, count: ArchiveReader.bufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                archive_read_data(archive, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                try? FileManager.default.removeItem(at: file)
                let message = Self.message(archive)
                // libarchive: "Incorrect passphrase" / "Passphrase required for this entry"
                if message.localizedCaseInsensitiveContains("passphrase") {
                    throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
                }
                throw ArchiveError.readFailed(message)
            }
            try output.write(contentsOf: buffer[0..<count])
        }
    }

    // MARK: Building the index

    // File type bits of a mode (AE_IFMT, AE_IFDIR, …); also used when writing.
    private static let typeMask: UInt32 = 0o170000
    static let typeDirectory: UInt32 = 0o040000
    static let typeSymlink: UInt32 = 0o120000
    static let typeRegular: UInt32 = 0o100000

    static func encryptedUnsupported(_ format: ArchiveFormat) -> String {
        String(localized: "encrypted \(format.displayName) archives aren’t supported yet", bundle: .module)
    }

    /// `password` is only needed for 7z with encrypted file names.
    private static func buildIndex(source: any ArchiveSource, rootDate: Date,
                                   password: String?) throws -> (ArchiveIndex, ArchiveFormat) {
        let reader = try ArchiveReader(source: source, password: password)
        let archive = reader.archive
        defer { reader.close() }

        var index = ArchiveIndex(rootDate: rootDate)
        var format = ArchiveFormat.zip
        var header: OpaquePointer?
        var position = 0
        var records: [RawEntry] = []
        while true {
            let status = archive_read_next_header(archive, &header)
            if status == ARCHIVE_EOF { break }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let header else {
                // Encrypted file names: 7z reports "Passphrase required …" or "Incorrect
                // passphrase"; RAR "RAR encryption support unavailable." / "Encryption is not supported"
                let reason = message(archive)
                if reason.localizedCaseInsensitiveContains("passphrase required") {
                    throw ArchiveError.passwordRequired
                }
                if reason.localizedCaseInsensitiveContains("incorrect passphrase") {
                    throw ArchiveError.wrongPassword
                }
                // Encrypted file names and a wrong password, in a format that doesn't check
                // passwords (7z): the decrypted header is garbage, libarchive reports a
                // decompression error.
                let detected = ArchiveFormat(detectedBy: archive)
                if password != nil, !detected.handler.verifiesPassword {
                    throw ArchiveError.wrongPassword
                }
                throw ArchiveError.openFailed(reason.localizedCaseInsensitiveContains("encrypt")
                                              ? encryptedUnsupported(detected) : reason)
            }
            if position == 0 { format = ArchiveFormat(detectedBy: archive) }
            defer {
                archive_read_data_skip(archive)
                position += 1
            }

            guard let path = Name(utf8: archive_entry_pathname_utf8(header), raw: archive_entry_pathname(header)) else {
                continue
            }

            let type = UInt32(archive_entry_filetype(header)) & typeMask
            let kind: ArchiveEntry.Kind
            switch type {
            case typeDirectory: kind = .directory
            case typeSymlink: kind = .symlink
            case typeRegular, 0: kind = .file
            default: continue   // devices, FIFOs, sockets from TARs
            }

            var permissions = UInt16(archive_entry_perm(header) & 0o777)
            if permissions == 0 { permissions = kind == .directory ? 0o755 : 0o644 }
            permissions |= kind == .directory ? 0o500 : 0o400   // the owner can always read

            let date = archive_entry_mtime_is_set(header) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(header))
                       + TimeInterval(archive_entry_mtime_nsec(header)) / 1e9)
                : rootDate

            let size = UInt64(max(0, archive_entry_size(header)))
            records.append(RawEntry(
                path: path, kind: kind, size: size, position: position, permissions: permissions, date: date,
                symlinkTarget: kind == .symlink ? Name(utf8: archive_entry_symlink_utf8(header),
                                                       raw: archive_entry_symlink(header)) : nil,
                // TAR hard link without data of its own: contents come from the target
                hardlink: kind == .file && size == 0 ? Name(utf8: nil, raw: archive_entry_hardlink(header)) : nil,
                isEncrypted: archive_entry_is_encrypted(header) != 0))
        }

        // Names that aren't UTF-8 (ZIPs without the UTF-8 flag, old TARs): guess the
        // encoding once for the whole archive
        let undecoded = records.flatMap { [$0.path, $0.symlinkTarget, $0.hardlink] }.compactMap { $0?.bytes }
        let encoding = undecoded.isEmpty ? String.Encoding.utf8 : NameEncoding.guess(for: undecoded)
        func text(_ name: Name) -> String {
            switch name {
            case .text(let text): text
            case .bytes(let data): NameEncoding.decode(data, as: encoding)
            }
        }

        for record in records {
            guard let components = ArchiveIndex.sanitize(text(record.path)) else {
                continue   // empty or unsafe path (e.g. "../")
            }
            var size = record.size
            var dataPosition = record.position
            if let link = record.hardlink {
                guard let targetPath = ArchiveIndex.sanitize(text(link)),
                      let target = index.lookup(path: targetPath.joined(separator: "/")),
                      target.kind == .file, let targetPosition = target.archiveIndex else { continue }
                size = target.size
                dataPosition = targetPosition
            }
            index.insert(path: components, kind: record.kind, size: size,
                         modificationDate: record.date, permissions: record.permissions,
                         symlinkTarget: record.symlinkTarget.map(text),
                         isEncrypted: record.isEncrypted, archiveIndex: dataPosition)
        }
        if position == 0 { format = ArchiveFormat(detectedBy: archive) }   // empty archive
        return (index, format)
    }

    /// A name from the archive: either readable already, or raw bytes in an unknown encoding.
    private enum Name {
        case text(String)
        case bytes(Data)

        /// libarchive returns UTF-8 if it could convert the name, otherwise only the raw bytes.
        init?(utf8: UnsafePointer<CChar>?, raw: UnsafePointer<CChar>?) {
            if let utf8 {
                self = .text(String(cString: utf8))
            } else if let raw {
                let data = Data(bytes: raw, count: strlen(raw))
                if let text = String(data: data, encoding: .utf8) { self = .text(text) } else { self = .bytes(data) }
            } else {
                return nil
            }
        }

        var bytes: Data? {
            if case .bytes(let data) = self { return data }
            return nil
        }
    }

    /// An entry as read in the first pass; names are decoded afterwards.
    private struct RawEntry {
        let path: Name
        let kind: ArchiveEntry.Kind
        let size: UInt64
        let position: Int
        let permissions: UInt16
        let date: Date
        let symlinkTarget: Name?
        let hardlink: Name?
        let isEncrypted: Bool
    }

    // MARK: libarchive

    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? String(localized: "unknown error", bundle: .module)
    }
}

/// libarchive converts names using the process locale. Apps and command-line tools run
/// with "C" unless configured otherwise, and then every UTF-8 name fails: libarchive only
/// reports a warning and returns no name. Set once for the whole process; nothing else in
/// Zippy depends on the locale.
let utf8Locale: Void = {
    setlocale(LC_CTYPE, "UTF-8")
}()

/// An open libarchive read pass over an ``ArchiveSource``.
/// Each pass has its own position; the source itself is only read with explicit offsets.
final class ArchiveReader {
    /// Size of the read buffers used with libarchive.
    static let bufferSize = 256 * 1024

    let archive: OpaquePointer
    private let state: Unmanaged<State>
    private var closed = false

    final class State {
        let source: any ArchiveSource
        var position: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: ArchiveReader.bufferSize, alignment: 16)
        init(source: any ArchiveSource) { self.source = source }
        deinit { buffer.deallocate() }
    }

    init(source: any ArchiveSource, password: String? = nil) throws {
        _ = utf8Locale
        guard let archive = archive_read_new() else { throw ArchiveError.openFailed("libarchive") }
        self.archive = archive
        self.state = Unmanaged.passRetained(State(source: source))

        for format in ArchiveFormat.readable {
            format.enableReading(on: archive)
        }
        if let password {
            for variant in Self.passwordVariants(password) {
                variant.withUnsafeBufferPointer { _ = archive_read_add_passphrase(archive, $0.baseAddress) }
            }
        }
        archive_read_set_callback_data(archive, state.toOpaque())
        archive_read_set_read_callback(archive) { _, data, buffer in
            let state = Unmanaged<State>.fromOpaque(data!).takeUnretainedValue()
            guard let count = try? state.source.read(into: state.buffer, at: UInt64(state.position)) else {
                return -1
            }
            state.position += Int64(count)
            buffer?.pointee = UnsafeRawPointer(state.buffer.baseAddress)
            return count
        }
        archive_read_set_seek_callback(archive) { _, data, offset, whence in
            let state = Unmanaged<State>.fromOpaque(data!).takeUnretainedValue()
            let size = Int64(state.source.size)
            let target: Int64 = switch whence {
            case SEEK_SET: offset
            case SEEK_CUR: state.position + offset
            case SEEK_END: size + offset
            default: -1
            }
            guard target >= 0 else { return Int64(ARCHIVE_FATAL) }
            state.position = min(target, size)
            return state.position
        }
        archive_read_set_skip_callback(archive) { _, data, request in
            let state = Unmanaged<State>.fromOpaque(data!).takeUnretainedValue()
            let skipped = min(request, Int64(state.source.size) - state.position)
            state.position += max(0, skipped)
            return max(0, skipped)
        }

        guard archive_read_open1(archive) == ARCHIVE_OK else {
            let reason = Archive.message(archive)
            close()
            throw ArchiveError.openFailed(reason)
        }
    }

    deinit { close() }

    /// Advances to the next header. ARCHIVE_WARN is not an error, e.g. when a UTF-8 name
    /// doesn't fit the process character set.
    @discardableResult
    func nextHeader() throws -> OpaquePointer {
        var header: OpaquePointer?
        let status = archive_read_next_header(archive, &header)
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let header else {
            throw ArchiveError.readFailed(Archive.message(archive))
        }
        return header
    }

    /// The same password in the byte sequences ZIP tools use: precomposed and decomposed
    /// UTF-8 (macOS tools often send "o" + "¨" instead of "ö"), plus Windows-1252 and DOS
    /// code page 437 for old ZipCrypto archives from Windows. libarchive tries them in order.
    static func passwordVariants(_ password: String) -> [[CChar]] {
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        let encodings: [Data?] = [
            password.precomposedStringWithCanonicalMapping.data(using: .utf8),
            password.decomposedStringWithCanonicalMapping.data(using: .utf8),
            password.data(using: .windowsCP1252),
            password.data(using: dos),
        ]
        var seen = Set<Data>()
        return encodings.compactMap { $0 }.filter { seen.insert($0).inserted }.map { data in
            data.map { CChar(bitPattern: $0) } + [0]
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        archive_read_free(archive)
        state.release()
    }
}
