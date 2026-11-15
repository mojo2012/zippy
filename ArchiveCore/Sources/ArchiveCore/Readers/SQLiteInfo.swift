import Foundation

/// `_info.txt`: what's in the database and how it's stored.
struct SQLiteInfo {
    let text: String

    init(database: SQLiteDatabase, header: Data?, size: UInt64, objects: [SQLiteDatabase.Object],
         rowCounts: [String: Int], isCoreData: Bool) {
        func pragma(_ name: String) -> String { database.scalar("PRAGMA \(name)") ?? "?" }
        let pageSize = Int(pragma("page_size")) ?? 0
        let pageCount = Int(pragma("page_count")) ?? 0

        var general: [(String, String)] = [
            ("File size", "\(Self.number(Int(size))) bytes (\(Self.number(pageCount)) pages of \(Self.number(pageSize)) bytes)"),
        ]
        if let writer = header.flatMap(Self.writerVersion) { general.append(("Last written by", "SQLite \(writer)")) }
        general += [
            ("Encoding", pragma("encoding")),
            ("Journal mode", pragma("journal_mode")),
            ("Auto vacuum", ["none", "full", "incremental"][Int(pragma("auto_vacuum")) ?? 0]),
            ("Free pages", pragma("freelist_count")),
            ("User version", pragma("user_version")),
            ("Application ID", Self.applicationID(Int(pragma("application_id")) ?? 0)),
        ]
        if isCoreData { general.append(("Created by", "Core Data (dates count from 2001)")) }

        var lines = Self.aligned(general)
        func section(_ title: String, _ rows: [(String, String)]) {
            guard !rows.isEmpty else { return }
            lines += ["", title] + Self.aligned(rows).map { "  " + $0 }
        }
        func named(_ type: String) -> [SQLiteDatabase.Object] {
            objects.filter { $0.type == type }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        section("Tables", named("table").map { table in
            let rows = rowCounts[table.name].map { "\(Self.number($0)) rows" } ?? "unreadable"
            let columns = database.rows("PRAGMA table_info(\(SQLiteDatabase.quote(table.name)))").count
            let references = Set(database.rows("PRAGMA foreign_key_list(\(SQLiteDatabase.quote(table.name)))")
                .compactMap { $0.count > 2 ? $0[2] : nil }).sorted()
            return (table.name, "\(rows), \(columns) columns"
                    + (references.isEmpty ? "" : ", references " + references.joined(separator: ", ")))
        })
        section("Views", named("view").map { ($0.name, rowCounts[$0.name].map { "\(Self.number($0)) rows" } ?? "unreadable") })
        section("Indexes", named("index").map { ($0.name, "on " + $0.table) })
        section("Triggers", named("trigger").map { ($0.name, "on " + $0.table) })
        lines += ["", "Read with SQLite \(database.scalar("SELECT sqlite_version()") ?? "?") by Zippy."]
        text = lines.joined(separator: "\n") + "\n"
    }

    /// Header bytes 96–99: SQLITE_VERSION_NUMBER of the library that last wrote the file.
    private static func writerVersion(_ header: Data) -> String? {
        guard header.count >= 100 else { return nil }
        let number = header[header.startIndex + 96 ..< header.startIndex + 100].reduce(0) { $0 << 8 | Int($1) }
        guard number > 3_000_000 else { return nil }
        return "\(number / 1_000_000).\(number / 1000 % 1000).\(number % 1000)"
    }

    /// Some formats put a four-letter code here, e.g. "GPKG" for GeoPackage.
    private static func applicationID(_ id: Int) -> String {
        guard id != 0 else { return "0" }
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: id >> (24 - 8 * $0)) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "\(id) (\"\(String(decoding: bytes, as: UTF8.self))\")"
        }
        return String(id)
    }

    private static func aligned(_ rows: [(String, String)]) -> [String] {
        let width = rows.map { SQLiteCSV.width($0.0) }.max() ?? 0
        return rows.map { $0.0 + String(repeating: " ", count: width - SQLiteCSV.width($0.0) + 2) + $0.1 }
    }

    /// "307,200": grouped, the same in every language.
    private static func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }
}
