import Foundation
import SQLite3

/// An SQLite database shown as files:
/// - per table and view a folder `<name>` with `<name>.csv` (columns padded to their widest
///   cell), `<name>.json`, `<name>.ddl` (the `CREATE` statement plus indexes and triggers)
///   and, if it has large blobs, a folder `blobs` with one file per blob
/// - `_schema.sql`: the whole schema, `_dump.sql`: schema and data like `sqlite3 .dump`,
///   `_info.txt`: an overview of the database
///
/// Everything is rendered when the database is opened: a file's size has to be known
/// before anyone reads it, and the column widths need every row anyway. The database
/// is only ever opened read-only.
final class SQLiteEntryReader: EntryReader, @unchecked Sendable {
    let index: ArchiveIndex
    let format = ArchiveFormat.sqlite
    /// Rendered files, by position.
    private let files: [URL]
    private let workDirectory: URL

    /// Every SQLite 3 database starts with this header.
    private static let magic = Data("SQLite format 3\0".utf8)

    static func canRead(_ source: any ArchiveSource) -> Bool {
        header(of: source, length: magic.count) == magic
    }

    private static func header(of source: any ArchiveSource, length: Int) -> Data? {
        guard source.size >= UInt64(length) else { return nil }
        var header = Data(count: length)
        let count = (try? header.withUnsafeMutableBytes { try source.read(into: $0, at: 0) }) ?? 0
        return count == length ? header : nil
    }

    init(source: any ArchiveSource, rootDate: Date) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workDirectory = directory
        do {
            let database = try SQLiteDatabase(path: try Self.databasePath(for: source, in: directory))
            var builder = Builder(directory: directory, rootDate: rootDate)
            try Self.render(database, header: Self.header(of: source, length: 100), size: source.size,
                            into: &builder)
            index = builder.index
            files = builder.files
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: workDirectory) }

    func extract(position: Int, to file: URL) throws {
        guard files.indices.contains(position) else { throw ArchiveError.notFound }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.copyItem(at: files[position], to: file)   // a clone on APFS
    }

    // MARK: Rendering

    private static let schemaFile = "_schema.sql"
    private static let dumpFile = "_dump.sql"
    private static let infoFile = "_info.txt"

    private static func render(_ database: SQLiteDatabase, header: Data?, size: UInt64,
                               into builder: inout Builder) throws {
        let objects = try database.objects()
        let shadowTables = database.shadowTables()
        let isCoreData = objects.contains { $0.name == "Z_METADATA" }
        var names = FileNames(reserved: [schemaFile, dumpFile, infoFile])
        var rowCounts: [String: Int] = [:]

        let tablesAndViews = objects.filter { $0.type == "table" || $0.type == "view" }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for object in tablesAndViews {
            let base = names.unique(for: object.name)
            let table = SQLiteTable(database: database, name: object.name, isCoreData: isCoreData)
            var blobs = BlobFolder(table: base)

            // Blob files are added to the builder while the CSV and JSON are written
            try builder.add([base, base + ".csv"]) { handle, builder in
                try Self.readable(handle) {
                    rowCounts[object.name] = try table.writeCSV(to: handle) { data, row, column in
                        try blobs.path(for: data, row: row, column: column, into: &builder)
                    }
                }
            }
            try builder.add([base, base + ".json"]) { handle, builder in
                try Self.readable(handle) {
                    try table.writeJSON(to: handle) { data, row, column in
                        try blobs.path(for: data, row: row, column: column, into: &builder)
                    }
                }
            }
            try builder.add([base, base + ".ddl"]) { handle, _ in
                try handle.write(contentsOf: Data(database.ddl(for: object, in: objects).utf8))
            }
        }

        try builder.add([schemaFile]) { handle, _ in
            let statements = objects.filter { !shadowTables.contains($0.name) }.compactMap(\.sql)
            try handle.write(contentsOf: Data(statements.map { $0 + ";\n" }.joined().utf8))
        }
        try builder.add([dumpFile]) { handle, _ in
            try Self.writeDump(database, objects: objects, shadowTables: shadowTables, to: handle)
        }
        try builder.add([infoFile]) { handle, _ in
            let info = SQLiteInfo(database: database, header: header, size: size, objects: objects,
                                  rowCounts: rowCounts, isCoreData: isCoreData)
            try handle.write(contentsOf: Data(info.text.utf8))
        }
    }

    /// A table that can't be read (a virtual table whose module this SQLite lacks, e.g. an
    /// FTS or R-tree extension) shows why instead of failing the whole database.
    private static func readable(_ handle: FileHandle, _ write: () throws -> Void) throws {
        do {
            try write()
        } catch {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
        }
    }

    /// Like `sqlite3 .dump`: schema and rows in creation order, in one transaction.
    private static func writeDump(_ database: SQLiteDatabase, objects: [SQLiteDatabase.Object],
                                  shadowTables: Set<String>, to handle: FileHandle) throws {
        var output = SQLiteOutput(handle: handle)
        output.write("PRAGMA foreign_keys=OFF;\nBEGIN TRANSACTION;\n")
        // Shadow tables of virtual tables are created and filled by the virtual table itself
        for object in objects where object.type == "table" && !shadowTables.contains(object.name) {
            if let sql = object.sql { output.write(sql + ";\n") }
            try SQLiteTable(database: database, name: object.name, isCoreData: false).writeInserts(to: &output)
        }
        if try database.hasTable("sqlite_sequence") {
            output.write("DELETE FROM sqlite_sequence;\n")
            try SQLiteTable(database: database, name: "sqlite_sequence", isCoreData: false).writeInserts(to: &output)
        }
        for object in objects where object.type != "table" {
            if let sql = object.sql { output.write(sql + ";\n") }
        }
        output.write("COMMIT;\n")
        try output.flush()
    }

    /// SQLite needs a file path. Other sources (block devices) are copied to a file first.
    private static func databasePath(for source: any ArchiveSource, in directory: URL) throws -> String {
        if let file = source as? FileSource { return file.url.path }
        let copy = directory.appendingPathComponent("database.sqlite")
        FileManager.default.createFile(atPath: copy.path, contents: nil)
        let handle = try FileHandle(forWritingTo: copy)
        defer { try? handle.close() }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: UInt64 = 0
        while offset < source.size {
            let count = try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: offset) }
            if count == 0 { break }
            try handle.write(contentsOf: buffer[0..<count])
            offset += UInt64(count)
        }
        return copy.path
    }

    // MARK: Helpers

    /// Collects the rendered files and their index entries.
    private struct Builder {
        let directory: URL
        let rootDate: Date
        var index: ArchiveIndex
        var files: [URL] = []

        init(directory: URL, rootDate: Date) {
            self.directory = directory
            self.rootDate = rootDate
            index = ArchiveIndex(rootDate: rootDate)
        }

        /// Writes a file and adds it at `path`. `write` may add further files (blobs) itself.
        mutating func add(_ path: [String], write: (FileHandle, inout Builder) throws -> Void) throws {
            let file = directory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try write(handle, &self)
            index.insert(path: path, kind: .file, size: try handle.offset(), modificationDate: rootDate,
                         permissions: 0o444, symlinkTarget: nil, isEncrypted: false, archiveIndex: files.count)
            files.append(file)
        }
    }

    /// The blob files of one table, in `<table>/blobs`, each written once.
    private struct BlobFolder {
        let table: String
        private var paths: [String: String] = [:]

        init(table: String) { self.table = table }

        /// "blobs/<row>-<column>.<ext>", relative to the table's CSV and JSON so the link
        /// still works when the table's folder is copied elsewhere. The extension is guessed
        /// from the content.
        mutating func path(for data: Data, row: Int, column: String, into builder: inout Builder) throws -> String {
            let key = "\(row)\u{0}\(column)"
            if let path = paths[key] { return path }
            let name = "\(row)-\(FileNames.clean(column)).\(BlobType.fileExtension(for: data))"
            try builder.add([table, "blobs", name]) { handle, _ in try handle.write(contentsOf: data) }
            let path = "blobs/" + name
            paths[key] = path
            return path
        }
    }

    /// File names for tables: "/" can't be in a file name, and after replacing it two names
    /// can collide (SQLite names are case-insensitive, and so is the volume).
    private struct FileNames {
        private var used: Set<String>

        init(reserved: [String]) {
            used = Set(reserved.map { ($0 as NSString).deletingPathExtension.lowercased() })
        }

        static func clean(_ name: String) -> String {
            let clean = name.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "∶")
            return clean.isEmpty || clean == "." || clean == ".." ? "_" + clean : clean
        }

        mutating func unique(for name: String) -> String {
            let base = Self.clean(name)
            var candidate = base
            var number = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) (\(number))"
                number += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}

/// File extensions for blobs, from their first bytes.
enum BlobType {
    static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + prefix.count && Array(bytes[offset ..< offset + prefix.count]) == prefix
        }
        func starts(_ text: String, at offset: Int = 0) -> Bool { starts(Array(text.utf8), at: offset) }

        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts("GIF8") { return "gif" }
        if starts("RIFF"), starts("WEBP", at: 8) { return "webp" }
        if starts("ftypheic", at: 4) || starts("ftypheix", at: 4) || starts("ftypmif1", at: 4) { return "heic" }
        if starts("ftypavif", at: 4) { return "avif" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if starts("%PDF") { return "pdf" }
        if starts("bplist") { return "plist" }
        if starts("SQLite format 3") { return "sqlite" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if starts([0x1F, 0x8B]) { return "gz" }
        if starts("<?xml") { return "xml" }
        // Text: valid UTF-8 without control characters (zero bytes are valid UTF-8 too)
        if let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { $0.value < 0x20 && !"\t\n\r".unicodeScalars.contains($0) }) {
            if (try? JSONSerialization.jsonObject(with: data, options: [])) != nil { return "json" }
            return "txt"
        }
        return "bin"
    }
}

/// A read-only SQLite connection with the few queries Zippy needs.
final class SQLiteDatabase {
    struct Object {
        let type: String   // "table", "view", "index", "trigger"
        let name: String
        let table: String
        let sql: String?
    }

    let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(status))
            sqlite3_close(handle)
            throw ArchiveError.openFailed(message)
        }
        self.handle = handle
    }

    deinit { sqlite3_close(handle) }

    /// Everything in the schema except SQLite's own tables, in creation order.
    func objects() throws -> [Object] {
        let statement = try prepare("""
            SELECT type, name, tbl_name, sql FROM sqlite_master
            WHERE name NOT LIKE 'sqlite_%' ORDER BY rowid
            """)
        defer { sqlite3_finalize(statement) }
        var objects: [Object] = []
        while try step(statement) {
            objects.append(Object(type: text(statement, 0) ?? "", name: text(statement, 1) ?? "",
                                  table: text(statement, 2) ?? "", sql: text(statement, 3)))
        }
        return objects
    }

    /// Internal tables of virtual tables (FTS, R-tree). Needs SQLite 3.37; empty before.
    func shadowTables() -> Set<String> {
        Set(rows("SELECT name FROM pragma_table_list WHERE type = 'shadow'").compactMap { $0.first ?? nil })
    }

    func hasTable(_ name: String) throws -> Bool {
        scalar("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = \(SQLiteSQL.literal(.text(name)))") != nil
    }

    /// The `CREATE` statement of a table or view, followed by those of its indexes and
    /// triggers (indexes SQLite creates itself have no SQL and are left out).
    func ddl(for object: Object, in objects: [Object]) -> String {
        let related = objects.filter {
            ($0.type == "index" || $0.type == "trigger") && $0.table == object.name && $0.sql != nil
        }
        let statements = ([object.sql] + related.map(\.sql)).compactMap { $0 }
        return statements.map { $0 + ";\n" }.joined(separator: "\n")
    }

    /// A single value, e.g. of a pragma.
    func scalar(_ sql: String) -> String? {
        rows(sql).first?.first ?? nil
    }

    /// All rows of a query as text; empty if it fails.
    func rows(_ sql: String) -> [[String?]] {
        guard let statement = try? prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [[String?]] = []
        while (try? step(statement)) == true {
            rows.append((0..<sqlite3_column_count(statement)).map { text(statement, $0) })
        }
        return rows
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ArchiveError.readFailed(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    /// `true` for a row, `false` when done.
    func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw ArchiveError.readFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    /// `"name"` with inner quotes doubled.
    static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
