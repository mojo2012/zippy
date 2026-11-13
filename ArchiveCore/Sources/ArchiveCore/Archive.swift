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
        case .openFailed(let reason): "Archiv lässt sich nicht öffnen: \(reason)"
        case .notFound: "Eintrag nicht gefunden."
        case .notAFile: "Eintrag ist keine Datei."
        case .passwordRequired: "Das Archiv ist passwortgeschützt."
        case .wrongPassword: "Das Passwort ist falsch."
        case .readFailed(let reason): "Lesen fehlgeschlagen: \(reason)"
        case .writeFailed(let reason): "Speichern fehlgeschlagen: \(reason)"
        }
    }
}

/// Archivformat, beim Öffnen am Inhalt erkannt. Bestimmt, wie gespeichert wird.
public enum ArchiveFormat: Sendable, Equatable {
    case zip
    case tar(Compression)
    case sevenZip
    /// RAR 4 und 5. Nur lesbar: RAR-Archive schreiben kann libarchive nicht.
    case rar

    /// Kompression um ein TAR herum.
    public enum Compression: Sendable, Equatable {
        case none, gzip, bzip2, compress, xz
    }

    /// Name des Dokument-Symbols in Zippy/Resources/Icons.
    public var iconName: String {
        switch self {
        case .zip: "zip"
        case .tar: "tgz"
        case .sevenZip: "7z"
        case .rar: "rar"
        }
    }

    /// Kann Zippy Änderungen in diesem Format speichern?
    public var isWritable: Bool { self != .rar }

    /// Für Meldungen: "ZIP", "TAR", "7z", "RAR".
    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .tar: "TAR"
        case .sevenZip: "7z"
        case .rar: "RAR"
        }
    }
}

/// Ein geöffnetes Archiv (ZIP, TAR, 7z oder RAR): Index plus Lesezugriff auf Dateien.
///
/// Lesen: Beim ersten Zugriff wird die Datei vollständig in einen Cache-Ordner
/// entpackt, danach wird von dort gelesen. So sind beliebige Offsets möglich,
/// auch wenn der Eintrag komprimiert ist. Der Cache wird bei ``close()`` gelöscht.
/// Bei komprimierten TARs heißt Entpacken: von vorne bis zur Datei durchlesen.
///
/// Thread-sicher: Entpacken passiert nacheinander, Lesen aus dem Cache parallel.
public final class Archive: @unchecked Sendable {
    public let source: any ArchiveSource
    /// Bei geteilten Archiven alle Teile, sonst leer.
    public private(set) var parts: [URL] = []
    public let index: ArchiveIndex
    public let format: ArchiveFormat
    /// Passwort für verschlüsselte Einträge (ZipCrypto oder AES).
    public let password: String?

    /// Enthält das Archiv verschlüsselte Dateien? Bei ZIP sind die Namen nie verschlüsselt,
    /// Auflisten geht also immer. 7z kann auch die Namen verschlüsseln: Dann wirft schon das
    /// Öffnen ohne Passwort ``ArchiveError/passwordRequired``. TAR kennt keine Verschlüsselung.
    public var needsPassword: Bool {
        index.entries.values.contains { $0.isEncrypted && $0.kind == .file }
    }

    /// Kann Zippy Änderungen speichern? Nicht bei RAR, nicht bei geteilten Archiven (die
    /// Teile müssten neu zerschnitten werden), und nicht bei verschlüsseltem 7z: libarchive
    /// kann 7z nur entschlüsseln, nicht verschlüsselt schreiben. Unverschlüsselt
    /// zurückzuschreiben wäre ein stilles Sicherheitsloch.
    public var canSave: Bool {
        format.isWritable && parts.isEmpty && !(format == .sevenZip && needsPassword)
    }

    private let cacheDirectory: URL
    private let lock = NSLock()
    private var extracted: [UInt64: URL] = [:]

    /// Archiv aus einer Datei.
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
            // libarchive liest hier nur diese eine Datei und meldet dann z. B.
            // "Too small block encountered" – unverständlich für Menschen.
            throw ArchiveError.openFailed("geteilte ZIPs (.z01 …) werden noch nicht unterstützt (\(reason))")
        }
    }

    /// Teil eines geteilten ZIPs von Info-ZIP/WinZip ("x.z01" … "x.zip"). Anders als
    /// `.zip.001` sind das keine einfach zerschnittenen Bytes.
    static func isSplitZip(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased().range(of: #"\.z\d\d$"#, options: .regularExpression) != nil
    }

    /// Archiv aus einer beliebigen Quelle, z. B. einem Block-Gerät.
    /// `date` gilt für Ordner ohne eigenes Datum.
    public init(source: any ArchiveSource, date: Date = Date(), password: String? = nil) throws {
        self.source = source
        self.password = password
        (self.index, self.format) = try Self.buildIndex(source: source, rootDate: date, password: password)
        // Verschlüsselte RAR-Daten erkennt libarchive, entschlüsseln kann es sie nicht.
        // 7z geht mit scripts/patches/libarchive-7zip-aes.patch.
        if format == .rar, index.entries.values.contains(where: { $0.isEncrypted }) {
            throw ArchiveError.openFailed(Self.encryptedUnsupported(format))
        }
        self.cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { close() }

    /// Name des Volumes: Dateiname ohne Endung, bei "x.tar.gz" ohne beide.
    /// Bei geteilten Archiven ohne Teil-Endung: "Fotos.part01.rar", "Fotos.7z.001" → "Fotos".
    public static func volumeName(for url: URL) -> String {
        let name = ArchiveParts.wholeName(of: url) ?? url.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return (stem as NSString).pathExtension.lowercased() == "tar" ? (stem as NSString).deletingPathExtension : stem
    }

    /// Löscht den Cache. Danach entpackt ``read(_:offset:length:)`` bei Bedarf neu.
    public func close() {
        lock.withLock {
            extracted.removeAll()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    /// Prüft das Passwort, indem die kleinste verschlüsselte Datei entpackt wird.
    /// Wirft ``ArchiveError/passwordRequired`` oder ``ArchiveError/wrongPassword``.
    public func checkPassword() throws {
        let candidates = index.entries.values.filter { $0.isEncrypted && $0.kind == .file && $0.size > 0 }
        guard let smallest = candidates.min(by: { $0.size < $1.size }) else { return }
        _ = try read(smallest.id, offset: 0, length: 1)
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
            guard !entry.isEncrypted || password != nil else { throw ArchiveError.passwordRequired }
            guard let position = entry.archiveIndex else { throw ArchiveError.notAFile }

            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let file = cacheDirectory.appendingPathComponent(String(entry.id))
            do {
                try extract(position: position, to: file)
            } catch ArchiveError.readFailed where format == .sevenZip && entry.isEncrypted {
                // 7z prüft das Passwort nicht: Ein falscher Schlüssel ergibt Datenmüll, den
                // erst das Entpacken bemerkt ("Decompression failed", Prüfsummenfehler).
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

        // ARCHIVE_WARN ist kein Fehler, z. B. wenn ein UTF-8-Name nicht in den
        // Zeichensatz des Prozesses passt (Hilfsprozess läuft mit "C").
        func nextHeader() throws {
            var header: OpaquePointer?
            let status = archive_read_next_header(archive, &header)
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw ArchiveError.readFailed(Self.message(archive))
            }
        }
        for _ in 0..<position {
            try nextHeader()
            archive_read_data_skip(archive)
        }
        try nextHeader()

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

    // MARK: Index aufbauen

    private static let typeMask: UInt32 = 0o170000
    private static let typeDirectory: UInt32 = 0o040000
    private static let typeSymlink: UInt32 = 0o120000
    private static let typeRegular: UInt32 = 0o100000

    // archive.h: ARCHIVE_FORMAT_BASE_MASK, ARCHIVE_FORMAT_TAR, ARCHIVE_FORMAT_ZIP
    private static let formatMask: Int32 = 0xff0000
    private static let formatTar: Int32 = 0x30000
    private static let format7Zip: Int32 = 0xE0000
    private static let formatRar: Int32 = 0xD0000
    private static let formatRar5: Int32 = 0x100000

    static func encryptedUnsupported(_ format: ArchiveFormat) -> String {
        "verschlüsselte \(format.displayName)-Archive werden noch nicht unterstützt"
    }

    /// `password` braucht es nur bei 7z mit verschlüsselten Dateinamen.
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
                // Verschlüsselte Dateinamen: 7z meldet "Passphrase required …" bzw. "Incorrect
                // passphrase"; RAR "RAR encryption support unavailable." / "Encryption is not supported"
                let reason = message(archive)
                if reason.localizedCaseInsensitiveContains("passphrase required") {
                    throw ArchiveError.passwordRequired
                }
                if reason.localizedCaseInsensitiveContains("incorrect passphrase") {
                    throw ArchiveError.wrongPassword
                }
                // 7z mit verschlüsselten Dateinamen und falschem Passwort: Der entschlüsselte
                // Kopf ist Datenmüll, libarchive meldet einen Entpackfehler.
                if password != nil, detectFormat(archive) == .sevenZip {
                    throw ArchiveError.wrongPassword
                }
                throw ArchiveError.openFailed(reason.localizedCaseInsensitiveContains("encrypt")
                                              ? encryptedUnsupported(detectFormat(archive)) : reason)
            }
            if position == 0 { format = detectFormat(archive) }
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
            default: continue   // Geräte, FIFOs, Sockets aus TARs
            }

            var permissions = UInt16(archive_entry_perm(header) & 0o777)
            if permissions == 0 { permissions = kind == .directory ? 0o755 : 0o644 }
            permissions |= kind == .directory ? 0o500 : 0o400   // Besitzer darf immer lesen

            let date = archive_entry_mtime_is_set(header) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(header))
                       + TimeInterval(archive_entry_mtime_nsec(header)) / 1e9)
                : rootDate

            let size = UInt64(max(0, archive_entry_size(header)))
            records.append(RawEntry(
                path: path, kind: kind, size: size, position: position, permissions: permissions, date: date,
                symlinkTarget: kind == .symlink ? Name(utf8: archive_entry_symlink_utf8(header),
                                                       raw: archive_entry_symlink(header)) : nil,
                // TAR-Hardlink ohne eigene Daten: Inhalt kommt vom Ziel
                hardlink: kind == .file && size == 0 ? Name(utf8: nil, raw: archive_entry_hardlink(header)) : nil,
                isEncrypted: archive_entry_is_encrypted(header) != 0))
        }

        // Namen, die kein UTF-8 sind (ZIPs ohne UTF-8-Kennung, alte TARs): Kodierung raten,
        // einmal für das ganze Archiv
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
                continue   // leerer oder unsicherer Pfad (z. B. "../")
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
        if position == 0 { format = detectFormat(archive) }   // leeres Archiv
        return (index, format)
    }

    /// Ein Name aus dem Archiv: schon lesbar, oder rohe Bytes in unbekannter Kodierung.
    private enum Name {
        case text(String)
        case bytes(Data)

        /// libarchive liefert UTF-8, wenn es den Namen umwandeln konnte, sonst nur die Bytes.
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

    /// Ein Eintrag, wie er beim ersten Durchgang gelesen wird; Namen werden danach dekodiert.
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

    private static func detectFormat(_ archive: OpaquePointer) -> ArchiveFormat {
        switch archive_format(archive) & formatMask {
        case formatTar:
            return switch archive_filter_code(archive, 0) {
            case ARCHIVE_FILTER_GZIP: .tar(.gzip)
            case ARCHIVE_FILTER_BZIP2: .tar(.bzip2)
            case ARCHIVE_FILTER_COMPRESS: .tar(.compress)
            case ARCHIVE_FILTER_XZ: .tar(.xz)
            default: .tar(.none)
            }
        case format7Zip:
            return .sevenZip
        case formatRar, formatRar5:
            return .rar
        default:
            return .zip
        }
    }

    // MARK: libarchive

    static func message(_ archive: OpaquePointer) -> String {
        archive_error_string(archive).map { String(cString: $0) } ?? "unbekannter Fehler"
    }
}

/// libarchive wandelt Namen über die Locale des Prozesses um. Apps und
/// Kommandozeilenprogramme laufen ohne Einstellung mit "C": Dann scheitert jeder
/// UTF-8-Name, libarchive meldet nur eine Warnung und liefert keinen Namen.
/// Einmalig für den ganzen Prozess, Zippy hat sonst nichts Locale-Abhängiges.
let utf8Locale: Void = {
    setlocale(LC_CTYPE, "UTF-8")
}()

/// Ein offener libarchive-Lesevorgang über eine ``ArchiveSource``.
/// Jeder Vorgang hat seine eigene Leseposition; die Quelle wird nur positionsbezogen gelesen.
final class ArchiveReader {
    let archive: OpaquePointer
    private let state: Unmanaged<State>
    private var closed = false

    final class State {
        let source: any ArchiveSource
        var position: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        init(source: any ArchiveSource) { self.source = source }
        deinit { buffer.deallocate() }
    }

    init(source: any ArchiveSource, password: String? = nil) throws {
        _ = utf8Locale
        guard let archive = archive_read_new() else { throw ArchiveError.openFailed("libarchive") }
        self.archive = archive
        self.state = Unmanaged.passRetained(State(source: source))

        archive_read_support_format_zip(archive)
        archive_read_support_format_tar(archive)
        archive_read_support_filter_gzip(archive)
        archive_read_support_filter_bzip2(archive)
        archive_read_support_filter_compress(archive)
        archive_read_support_filter_xz(archive)
        archive_read_support_format_7zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
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

    /// Dasselbe Passwort in den Byte-Folgen, die ZIP-Programme verwenden: UTF-8
    /// zusammengesetzt und zerlegt (macOS-Werkzeuge schicken oft "o" + "¨" statt "ö"),
    /// dazu Windows-1252 und DOS-Codepage 437 für alte ZipCrypto-Archive aus Windows.
    /// libarchive probiert alle der Reihe nach.
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
