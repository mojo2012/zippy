import CArchive
import Foundation

/// Bearbeitbare Sicht auf ein ``Archive`` (ZIP oder TAR).
///
/// Das Original bleibt bis zum Speichern unangetastet. Neue und geänderte Dateien
/// liegen in einem Arbeitsordner, Löschen und Umbenennen ändern nur den Baum im
/// Speicher. ``save(to:)`` schreibt daraus ein neues Archiv im selben Format,
/// ``saveReplacing(_:ifUnchangedSince:)`` ersetzt damit das Original.
///
/// Pfade sind relativ zum Wurzelordner (`"ordner/datei.txt"`, ein führendes `/` ist
/// erlaubt). Fehler sind `POSIXError`, damit das Dateisystem sie direkt weitergeben kann.
///
/// Vom System angelegte Dateien wie `.DS_Store` sind sichtbar, zählen aber nicht als
/// Änderung und werden nicht gespeichert (siehe ``isSystemFile(_:)``).
///
/// Thread-sicher über eine Sperre.
public final class EditableArchive: @unchecked Sendable {
    public struct Node: Sendable, Equatable {
        public let id: UInt64
        public fileprivate(set) var parentID: UInt64
        public fileprivate(set) var name: String
        public let kind: ArchiveEntry.Kind
        public fileprivate(set) var size: UInt64
        public fileprivate(set) var modificationDate: Date
        /// Nur die Rechte-Bits (rwxrwxrwx).
        public fileprivate(set) var permissions: UInt16
        public let symlinkTarget: String?
        /// Inhalt liegt noch verschlüsselt im Archiv.
        public fileprivate(set) var isEncrypted: Bool
        fileprivate var content: Content
        /// Stammt aus dem Original (dann wird er auch mit Systemnamen gespeichert).
        fileprivate let fromArchive: Bool

        public var isDirectory: Bool { kind == .directory }
    }

    fileprivate enum Content: Sendable, Equatable {
        case none                 // Ordner, Link
        case original(UInt64)     // Eintrag im Archive
        case staged               // Datei im Arbeitsordner
    }

    public static let rootID = ArchiveIndex.rootID

    public let archive: Archive
    /// Nur lesbar, z. B. wenn verschlüsselte Dateien ohne Passwort nicht umkopiert werden können.
    public let isReadOnly: Bool

    private let lock = NSLock()
    private var nodes: [UInt64: Node] = [:]
    private var childrenByKey: [UInt64: [String: UInt64]] = [:]
    private var nextID: UInt64
    private var changed = false
    private var descriptors: [UInt64: Int32] = [:]
    private var attributes: [UInt64: [String: Data]] = [:]
    private let workDirectory: URL

    public init(archive: Archive, readOnly: Bool = false) {
        self.archive = archive
        self.isReadOnly = readOnly || !archive.canSave
            || (archive.needsPassword && archive.password == nil)
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-edit-\(UUID().uuidString)", isDirectory: true)
        for entry in archive.index.entries.values {
            nodes[entry.id] = Node(
                id: entry.id, parentID: entry.parentID, name: entry.name, kind: entry.kind, size: entry.size,
                modificationDate: entry.modificationDate, permissions: entry.permissions,
                symlinkTarget: entry.symlinkTarget, isEncrypted: entry.isEncrypted,
                content: entry.kind == .file ? .original(entry.id) : .none, fromArchive: true)
            if entry.id != Self.rootID {
                childrenByKey[entry.parentID, default: [:]][Self.key(entry.name)] = entry.id
            }
        }
        nextID = (archive.index.entries.keys.max() ?? Self.rootID) + 1
    }

    deinit { close() }

    /// Schließt offene Dateien und löscht den Arbeitsordner. Nicht gespeicherte Änderungen gehen verloren.
    public func close() {
        lock.withLock {
            for descriptor in descriptors.values { Darwin.close(descriptor) }
            descriptors.removeAll()
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    /// Gibt es Änderungen, die gespeichert werden müssen?
    public var hasChanges: Bool { lock.withLock { changed } }

    // MARK: Lesen

    public func node(_ id: UInt64) -> Node? { lock.withLock { nodes[id] } }

    public func node(at path: String) -> Node? { lock.withLock { resolve(path) } }

    public func children(of id: UInt64) -> [Node] {
        lock.withLock {
            (childrenByKey[id] ?? [:]).values.compactMap { nodes[$0] }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// Liest bis zu `length` Bytes ab `offset`.
    public func read(_ id: UInt64, offset: UInt64, length: Int) throws -> Data {
        try lock.withLock {
            guard let node = nodes[id] else { throw POSIXError(.ENOENT) }
            guard node.kind == .file else { throw POSIXError(.EISDIR) }
            switch node.content {
            case .original(let entryID):
                return try archive.read(entryID, offset: offset, length: length)
            case .staged:
                guard offset < node.size, length > 0 else { return Data() }
                let descriptor = try descriptor(for: id)
                var data = Data(count: min(length, Int(node.size - offset)))
                let count = data.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
                guard count >= 0 else { throw POSIXError(.EIO) }
                return data.prefix(count)
            case .none:
                throw POSIXError(.EISDIR)
            }
        }
    }

    /// Statt `Archive.contents(of:)`: auch für neue und geänderte Dateien.
    public func contents(of id: UInt64) throws -> Data {
        guard let node = node(id) else { throw POSIXError(.ENOENT) }
        return try read(id, offset: 0, length: Int(node.size))
    }

    // MARK: Ändern

    @discardableResult
    public func createFile(at path: String, permissions: UInt16 = 0o644) throws -> Node {
        try mutate {
            let (parent, name) = try parentAndName(of: path)
            let node = Node(id: makeID(), parentID: parent.id, name: name, kind: .file, size: 0,
                            modificationDate: Date(), permissions: (permissions & 0o777) | 0o400,
                            symlinkTarget: nil, isEncrypted: false, content: .staged, fromArchive: false)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let descriptor = open(stagedFile(node.id).path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            descriptors[node.id] = descriptor
            insert(node)
            return node
        }
    }

    @discardableResult
    public func createDirectory(at path: String, permissions: UInt16 = 0o755) throws -> Node {
        try mutate {
            let (parent, name) = try parentAndName(of: path)
            let node = Node(id: makeID(), parentID: parent.id, name: name, kind: .directory, size: 0,
                            modificationDate: Date(), permissions: (permissions & 0o777) | 0o700,
                            symlinkTarget: nil, isEncrypted: false, content: .none, fromArchive: false)
            insert(node)
            return node
        }
    }

    @discardableResult
    public func createSymlink(at path: String, target: String) throws -> Node {
        try mutate {
            let (parent, name) = try parentAndName(of: path)
            let node = Node(id: makeID(), parentID: parent.id, name: name, kind: .symlink,
                            size: UInt64(target.utf8.count), modificationDate: Date(), permissions: 0o755,
                            symlinkTarget: target, isEncrypted: false, content: .none, fromArchive: false)
            insert(node)
            return node
        }
    }

    /// Löscht eine Datei oder einen Link (wie `unlink`).
    public func removeFile(at path: String) throws {
        try mutate {
            guard let node = resolve(path), node.id != Self.rootID else { throw POSIXError(.ENOENT) }
            guard !node.isDirectory else { throw POSIXError(.EPERM) }
            detach(node)
        }
    }

    /// Löscht einen leeren Ordner (wie `rmdir`).
    public func removeDirectory(at path: String) throws {
        try mutate {
            guard let node = resolve(path) else { throw POSIXError(.ENOENT) }
            guard node.id != Self.rootID else { throw POSIXError(.EBUSY) }
            guard node.isDirectory else { throw POSIXError(.ENOTDIR) }
            guard (childrenByKey[node.id] ?? [:]).isEmpty else { throw POSIXError(.ENOTEMPTY) }
            detach(node)
        }
    }

    /// Umbenennen oder Verschieben (wie `rename`): ein vorhandenes Ziel wird ersetzt.
    public func move(from source: String, to destination: String) throws {
        try mutate {
            guard let node = resolve(source), node.id != Self.rootID else { throw POSIXError(.ENOENT) }
            let (parent, name) = try parentAndName(of: destination, allowExisting: true)
            // Ordner nicht in sich selbst verschieben
            var ancestor = parent.id
            while true {
                if ancestor == node.id { throw POSIXError(.EINVAL) }
                if ancestor == Self.rootID { break }
                ancestor = nodes[ancestor]?.parentID ?? Self.rootID
            }
            if let existingID = childrenByKey[parent.id]?[Self.key(name)], existingID != node.id,
               let existing = nodes[existingID] {
                if node.isDirectory {
                    guard existing.isDirectory else { throw POSIXError(.ENOTDIR) }
                    guard (childrenByKey[existing.id] ?? [:]).isEmpty else { throw POSIXError(.ENOTEMPTY) }
                } else if existing.isDirectory {
                    throw POSIXError(.EISDIR)
                }
                detach(existing)
            }
            let wasSystemFile = excluded(node.id)
            childrenByKey[node.parentID]?[Self.key(node.name)] = nil
            touch(node.parentID, systemFile: wasSystemFile)
            nodes[node.id]?.parentID = parent.id
            nodes[node.id]?.name = name
            childrenByKey[parent.id, default: [:]][Self.key(name)] = node.id
            touch(parent.id, systemFile: wasSystemFile && excluded(node.id))
        }
    }

    /// Schreibt in eine Datei; Dateien aus dem Archiv werden dafür erst umkopiert.
    @discardableResult
    public func write(_ id: UInt64, bytes: UnsafeRawBufferPointer, at offset: UInt64) throws -> Int {
        try mutate {
            let descriptor = try materialize(id)
            let count = pwrite(descriptor, bytes.baseAddress, bytes.count, off_t(offset))
            guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            nodes[id]!.size = max(nodes[id]!.size, offset + UInt64(count))
            modified(id)
            return count
        }
    }

    public func write(_ id: UInt64, data: Data, at offset: UInt64) throws {
        try data.withUnsafeBytes { _ = try write(id, bytes: $0, at: offset) }
    }

    public func truncate(_ id: UInt64, to size: UInt64) throws {
        try mutate {
            guard nodes[id]?.kind == .file else { throw POSIXError(.EISDIR) }
            if nodes[id]!.size == size { return }
            let descriptor = try materialize(id, keepingContents: size > 0)
            guard ftruncate(descriptor, off_t(size)) == 0 else { throw POSIXError(.EIO) }
            nodes[id]!.size = size
            modified(id)
        }
    }

    public func setModificationDate(_ id: UInt64, to date: Date) throws {
        try mutate {
            guard let node = nodes[id] else { throw POSIXError(.ENOENT) }
            guard abs(node.modificationDate.timeIntervalSince(date)) >= 0.001 else { return }
            nodes[id]!.modificationDate = date
            if !excluded(id) { changed = true }
        }
    }

    public func setPermissions(_ id: UInt64, to permissions: UInt16) throws {
        try mutate {
            guard let node = nodes[id] else { throw POSIXError(.ENOENT) }
            let value = (permissions & 0o777) | (node.isDirectory ? 0o700 : 0o400)
            guard node.permissions != value else { return }
            nodes[id]!.permissions = value
            if !excluded(id) { changed = true }
        }
    }

    // MARK: Erweiterte Attribute (nur im Speicher, ZIP speichert sie nicht)

    public func extendedAttribute(_ name: String, of id: UInt64) -> Data? {
        lock.withLock { attributes[id]?[name] }
    }

    public func extendedAttributeNames(of id: UInt64) -> [String] {
        lock.withLock { attributes[id].map { Array($0.keys).sorted() } ?? [] }
    }

    public func setExtendedAttribute(_ name: String, to value: Data?, of id: UInt64) throws {
        try lock.withLock {
            guard !isReadOnly else { throw POSIXError(.EROFS) }
            guard nodes[id] != nil else { throw POSIXError(.ENOENT) }
            attributes[id, default: [:]][name] = value
        }
    }

    // MARK: Systemdateien

    /// Namen, die macOS selbst anlegt und die nicht ins Archiv gehören.
    public static func isSystemName(_ name: String) -> Bool {
        name.hasPrefix("._") || [".DS_Store", ".TemporaryItems", ".Trashes", ".fseventsd",
                                 ".Spotlight-V100", ".DocumentRevisions-V100", ".apdisk"].contains(name)
    }

    /// Neu angelegt und selbst oder in einem Ordner mit Systemnamen: wird nicht gespeichert.
    public func isSystemFile(_ id: UInt64) -> Bool {
        lock.withLock { excluded(id) }
    }

    private func excluded(_ id: UInt64) -> Bool {
        guard let node = nodes[id], !node.fromArchive else { return false }
        var current = node
        while current.id != Self.rootID {
            if Self.isSystemName(current.name) { return true }
            guard let parent = nodes[current.parentID] else { return false }
            current = parent
        }
        return false
    }

    // MARK: Speichern

    /// Datum und Größe einer Datei, um fremde Änderungen am Original zu erkennen.
    public struct FileStamp: Equatable, Sendable {
        public let size: UInt64
        public let modificationDate: Date

        public init(of url: URL) throws {
            // Nicht über resourceValues: Die URL merkt sich alte Werte.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        }
    }

    /// Speichert neben `original` und ersetzt es. Wurde das Original inzwischen von
    /// außen geändert, bleibt es stehen und die Änderungen landen in einer Kopie
    /// "<Name> (bearbeitet).zip". Gibt zurück, wohin gespeichert wurde.
    @discardableResult
    public func saveReplacing(_ original: URL, ifUnchangedSince stamp: FileStamp) throws -> URL {
        let directory = original.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(original.lastPathComponent).zippy-\(UUID().uuidString.prefix(8))")
        do {
            try save(to: temporary)
            if (try? FileStamp(of: original)) == stamp {
                _ = try FileManager.default.replaceItemAt(original, withItemAt: temporary)
                return original
            }
            let copy = Self.unusedURL(like: original, suffix: "bearbeitet")
            try FileManager.default.moveItem(at: temporary, to: copy)
            return copy
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// "<Name> (<suffix>).zip", "<Name> (<suffix> 2).zip" … – der erste freie Name.
    /// Doppelte Endungen wie ".tar.gz" bleiben zusammen.
    public static func unusedURL(like url: URL, suffix: String) -> URL {
        var base = url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        if (base as NSString).pathExtension.lowercased() == "tar" {
            base = (base as NSString).deletingPathExtension
            ext = ".tar" + ext
        }
        var number = 1
        while true {
            let name = number == 1 ? "\(base) (\(suffix))\(ext)" : "\(base) (\(suffix) \(number))\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Schreibt den aktuellen Stand im Format des Originals nach `destination`:
    /// ZIP bleibt ZIP, TAR bleibt TAR mit derselben Kompression, 7z bleibt 7z (LZMA2).
    ///
    /// Alles wird neu komprimiert (libarchive kann komprimierte Daten nicht direkt
    /// übernehmen). Unveränderte Dateien werden dafür in Archivreihenfolge gelesen.
    /// War ein ZIP verschlüsselt, wird mit demselben Passwort per AES-256 verschlüsselt.
    public func save(to destination: URL) throws {
        try lock.withLock {
            _ = utf8Locale
            guard let writer = archive_write_new() else { throw ArchiveError.writeFailed("libarchive") }
            defer { archive_write_free(writer) }
            var status: Int32
            switch archive.format {
            case .zip:
                status = archive_write_set_format_zip(writer)
                if status == ARCHIVE_OK, archive.needsPassword, let password = archive.password {
                    status = archive_write_set_options(writer, "zip:encryption=aes256")
                    if status == ARCHIVE_OK {
                        status = archive_write_set_passphrase(writer, password.precomposedStringWithCanonicalMapping)
                    }
                }
            case .tar(let compression):
                // pax: lange Namen, UTF-8, Nanosekunden; ohne pax-Erweiterungen, wo nicht nötig
                status = archive_write_set_format_pax_restricted(writer)
                if status == ARCHIVE_OK {
                    status = switch compression {
                    case .none: ARCHIVE_OK
                    case .gzip: archive_write_add_filter_gzip(writer)
                    case .bzip2: archive_write_add_filter_bzip2(writer)
                    case .compress: archive_write_add_filter_compress(writer)
                    case .xz: archive_write_add_filter_xz(writer)
                    }
                }
            case .sevenZip:
                status = archive_write_set_format_7zip(writer)
                if status == ARCHIVE_OK { status = archive_write_set_options(writer, "7zip:compression=lzma2") }
            case .rar:
                throw ArchiveError.writeFailed("RAR-Archive lassen sich nicht schreiben")
            }
            guard status == ARCHIVE_OK else { throw ArchiveError.writeFailed(Archive.message(writer)) }
            try? FileManager.default.removeItem(at: destination)
            guard archive_write_open_filename(writer, destination.path) == ARCHIVE_OK else {
                throw ArchiveError.writeFailed(Archive.message(writer))
            }

            // Ordner und Links sofort, Dateien danach (Originale in Archivreihenfolge)
            // Mehrere Knoten pro Position: Hardlinks aus einem TAR
            var originals: [Int: [(node: Node, path: String)]] = [:]
            var staged: [(node: Node, path: String)] = []
            for (node, path) in tree() {
                switch node.kind {
                case .directory, .symlink:
                    try writeHeader(node, path: path, to: writer)
                case .file:
                    if case .original(let entryID) = node.content,
                       let position = archive.index.entry(entryID)?.archiveIndex {
                        originals[position, default: []].append((node, path))
                    } else {
                        staged.append((node, path))
                    }
                }
            }
            if !originals.isEmpty { try copyOriginals(originals, to: writer) }
            for (node, path) in staged {
                try writeHeader(node, path: path, to: writer)
                let descriptor = try descriptor(for: node.id)
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                var offset: off_t = 0
                while offset < off_t(node.size) {
                    let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
                    guard count > 0 else { throw ArchiveError.writeFailed("Arbeitsdatei nicht lesbar") }
                    try writeData(buffer, count: count, to: writer)
                    offset += off_t(count)
                }
            }
            guard archive_write_close(writer) == ARCHIVE_OK else {
                throw ArchiveError.writeFailed(Archive.message(writer))
            }
        }
    }

    /// Liest das Original einmal von vorne und übernimmt die noch gültigen Dateien.
    private func copyOriginals(_ originals: [Int: [(node: Node, path: String)]], to writer: OpaquePointer) throws {
        let reader = try ArchiveReader(source: archive.source, password: archive.password)
        defer { reader.close() }
        let last = originals.keys.max()!
        var header: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        for position in 0...last {
            let status = archive_read_next_header(reader.archive, &header)
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw ArchiveError.readFailed(Archive.message(reader.archive))
            }
            guard let targets = originals[position], let (node, path) = targets.first else {
                archive_read_data_skip(reader.archive)
                continue
            }
            try writeHeader(node, path: path, to: writer)
            while true {
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader.archive, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { throw ArchiveError.readFailed(Archive.message(reader.archive)) }
                try writeData(buffer, count: count, to: writer)
            }
            // Weitere Namen derselben Daten bleiben Hardlinks (nur TAR kennt das)
            for (other, otherPath) in targets.dropFirst() {
                try writeHeader(other, path: otherPath, hardlinkTo: path, to: writer)
            }
        }
    }

    private func writeHeader(_ node: Node, path: String, hardlinkTo linkTarget: String? = nil,
                             to writer: OpaquePointer) throws {
        guard let entry = archive_entry_new() else { throw ArchiveError.writeFailed("libarchive") }
        defer { archive_entry_free(entry) }
        archive_entry_copy_pathname(entry, path.precomposedStringWithCanonicalMapping)
        switch node.kind {
        case .directory: archive_entry_set_filetype(entry, 0o040000)
        case .symlink:
            archive_entry_set_filetype(entry, 0o120000)
            archive_entry_copy_symlink(entry, (node.symlinkTarget ?? "").precomposedStringWithCanonicalMapping)
        case .file:
            archive_entry_set_filetype(entry, 0o100000)
            if let linkTarget {
                archive_entry_copy_hardlink(entry, linkTarget.precomposedStringWithCanonicalMapping)
                archive_entry_set_size(entry, 0)
            } else {
                archive_entry_set_size(entry, Int64(node.size))
            }
        }
        archive_entry_set_perm(entry, mode_t(node.permissions))
        // TAR speichert Besitzer; sonst gehört beim Entpacken als root alles root
        archive_entry_set_uid(entry, la_int64_t(getuid()))
        archive_entry_set_gid(entry, la_int64_t(getgid()))
        let seconds = node.modificationDate.timeIntervalSince1970.rounded(.down)
        archive_entry_set_mtime(entry, time_t(seconds),
                                Int((node.modificationDate.timeIntervalSince1970 - seconds) * 1e9))
        let status = archive_write_header(writer, entry)
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw ArchiveError.writeFailed(Archive.message(writer))
        }
    }

    private func writeData(_ buffer: [UInt8], count: Int, to writer: OpaquePointer) throws {
        let written = buffer.withUnsafeBytes { archive_write_data(writer, $0.baseAddress, count) }
        guard written == count else { throw ArchiveError.writeFailed(Archive.message(writer)) }
    }

    /// Alle zu speichernden Einträge mit Pfad, Eltern vor Kindern, ohne Systemdateien.
    private func tree() -> [(Node, String)] {
        var result: [(Node, String)] = []
        func visit(_ id: UInt64, prefix: String) {
            let children = (childrenByKey[id] ?? [:]).values.compactMap { nodes[$0] }.sorted { $0.name < $1.name }
            for child in children where !excluded(child.id) {
                let path = prefix + child.name
                result.append((child, path))
                if child.isDirectory { visit(child.id, prefix: path + "/") }
            }
        }
        visit(Self.rootID, prefix: "")
        return result
    }

    // MARK: Intern

    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping }

    private func mutate<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard !isReadOnly else { throw POSIXError(.EROFS) }
            return try body()
        }
    }

    private func resolve(_ path: String) -> Node? {
        var current = nodes[Self.rootID]!
        for component in path.split(separator: "/") where !component.isEmpty {
            guard current.isDirectory, let id = childrenByKey[current.id]?[Self.key(String(component))],
                  let next = nodes[id] else { return nil }
            current = next
        }
        return current
    }

    private func parentAndName(of path: String, allowExisting: Bool = false) throws -> (Node, String) {
        var components = path.split(separator: "/").map(String.init)
        guard let name = components.popLast(), name != ".", name != ".." else { throw POSIXError(.EINVAL) }
        guard let parent = resolve(components.joined(separator: "/")) else { throw POSIXError(.ENOENT) }
        guard parent.isDirectory else { throw POSIXError(.ENOTDIR) }
        if !allowExisting, childrenByKey[parent.id]?[Self.key(name)] != nil { throw POSIXError(.EEXIST) }
        return (parent, name)
    }

    private func insert(_ node: Node) {
        nodes[node.id] = node
        childrenByKey[node.parentID, default: [:]][Self.key(node.name)] = node.id
        touch(node.parentID, systemFile: excluded(node.id))
    }

    /// Nimmt einen Eintrag aus dem Baum. Er bleibt in `nodes`, damit offene Dateien weiter gehen.
    private func detach(_ node: Node) {
        let systemFile = excluded(node.id)
        childrenByKey[node.parentID]?[Self.key(node.name)] = nil
        touch(node.parentID, systemFile: systemFile)
        nodes[node.id]?.parentID = 0
    }

    /// Ordnerinhalt hat sich geändert.
    private func touch(_ directoryID: UInt64, systemFile: Bool) {
        guard !systemFile else { return }
        nodes[directoryID]?.modificationDate = Date()
        changed = true
    }

    private func modified(_ id: UInt64) {
        nodes[id]?.modificationDate = Date()
        if !excluded(id) { changed = true }
    }

    private func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }

    private func stagedFile(_ id: UInt64) -> URL {
        workDirectory.appendingPathComponent(String(id))
    }

    private func descriptor(for id: UInt64) throws -> Int32 {
        if let descriptor = descriptors[id] { return descriptor }
        let descriptor = open(stagedFile(id).path, O_RDWR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        descriptors[id] = descriptor
        return descriptor
    }

    /// Sorgt dafür, dass die Datei im Arbeitsordner liegt, und gibt ihren Deskriptor.
    private func materialize(_ id: UInt64, keepingContents: Bool = true) throws -> Int32 {
        guard let node = nodes[id] else { throw POSIXError(.ENOENT) }
        guard node.kind == .file else { throw POSIXError(.EISDIR) }
        guard case .original(let entryID) = node.content else { return try descriptor(for: id) }
        guard !node.isEncrypted || archive.password != nil else { throw POSIXError(.EACCES) }

        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let descriptor = open(stagedFile(id).path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        if keepingContents {
            var offset: UInt64 = 0
            while offset < node.size {
                let chunk = try archive.read(entryID, offset: offset, length: 1 << 20)
                if chunk.isEmpty { break }
                let written = chunk.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, off_t(offset)) }
                guard written == chunk.count else { Darwin.close(descriptor); throw POSIXError(.EIO) }
                offset += UInt64(chunk.count)
            }
        }
        descriptors[id] = descriptor
        nodes[id]!.content = .staged
        nodes[id]!.isEncrypted = false
        if !keepingContents { nodes[id]!.size = 0 }
        return descriptor
    }
}
