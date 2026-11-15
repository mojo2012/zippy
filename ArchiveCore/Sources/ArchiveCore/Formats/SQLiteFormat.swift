import Foundation

/// SQLite database, read with the system's SQLite rather than libarchive
/// (``SQLiteEntryReader``). Read-only: the files are a view of the tables.
struct SQLiteFormat: ArchiveFormatHandler {
    var displayName: String { "SQLite" }
    var iconName: String { "db" }
    var isWritable: Bool { false }

    func configureWriter(_ writer: OpaquePointer, password: String?) throws {
        throw ArchiveError.writeFailed(String(localized: "SQLite databases are read-only in Zippy", bundle: .module))
    }
}
