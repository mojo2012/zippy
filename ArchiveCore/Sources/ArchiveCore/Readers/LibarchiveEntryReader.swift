import CArchive
import Foundation

/// Entries of the formats libarchive reads: ZIP, TAR, 7z, RAR.
///
/// Listing is one pass over all headers. Extracting a file is another pass up to its
/// position; libarchive can't jump to an entry.
final class LibarchiveEntryReader: EntryReader, @unchecked Sendable {
    let index: ArchiveIndex
    let format: ArchiveFormat
    private let source: any ArchiveSource
    private let password: String?

    /// `password` is needed to list 7z archives with encrypted file names.
    init(source: any ArchiveSource, rootDate: Date, password: String?) throws {
        self.source = source
        self.password = password
        (index, format) = try Self.buildIndex(source: source, rootDate: rootDate, password: password)
    }

    func extract(position: Int, to file: URL) throws {
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
                let message = Archive.message(archive)
                // libarchive: "Incorrect passphrase" / "Passphrase required for this entry"
                if message.localizedCaseInsensitiveContains("passphrase") {
                    throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
                }
                throw ArchiveError.readFailed(message)
            }
            try output.write(contentsOf: buffer[0..<count])
        }
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
                let reason = Archive.message(archive)
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
                                              ? Archive.encryptedUnsupported(detected) : reason)
            }
            if position == 0 { format = ArchiveFormat(detectedBy: archive) }
            defer {
                archive_read_data_skip(archive)
                position += 1
            }

            guard let path = Name(utf8: archive_entry_pathname_utf8(header), raw: archive_entry_pathname(header)) else {
                continue
            }

            let type = UInt32(archive_entry_filetype(header)) & Archive.typeMask
            let kind: ArchiveEntry.Kind
            switch type {
            case Archive.typeDirectory: kind = .directory
            case Archive.typeSymlink: kind = .symlink
            case Archive.typeRegular, 0: kind = .file
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
}

extension Archive {
    // File type bits of a mode (AE_IFMT, AE_IFDIR, …); also used when writing.
    static let typeMask: UInt32 = 0o170000
    static let typeDirectory: UInt32 = 0o040000
    static let typeSymlink: UInt32 = 0o120000
    static let typeRegular: UInt32 = 0o100000

    static func encryptedUnsupported(_ format: ArchiveFormat) -> String {
        String(localized: "encrypted \(format.displayName) archives aren’t supported yet", bundle: .module)
    }

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

        for format in ArchiveFormat.libarchiveFormats {
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
