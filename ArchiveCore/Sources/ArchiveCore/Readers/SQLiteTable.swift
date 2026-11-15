import Foundation
import SQLite3

/// A value as SQLite stores it.
enum SQLiteValue {
    case null
    case integer(Int64)
    /// The number and SQLite's own text for it ("249.0", "1.5e+20").
    case real(Double, String)
    case text(String)
    case blob(Data)
}

/// A column of a result, with what's needed to show its values.
struct SQLiteColumn {
    let name: String
    let declaredType: String?
    /// Core Data stores dates as seconds since 2001.
    let isCoreData: Bool

    /// Columns declared as DATE, DATETIME, TIMESTAMP and the like hold dates. SQLite has no
    /// date type: they can be text, Unix time, Julian days, or (Core Data) seconds since 2001.
    var isDate: Bool {
        guard let type = declaredType?.uppercased() else { return false }
        return type.contains("DATE") || type.contains("TIMESTAMP")
    }

    /// DATE without TIME: midnight is shown as just the day.
    var isDateOnly: Bool {
        guard let type = declaredType?.uppercased() else { return false }
        return type.contains("DATE") && !type.contains("TIME")
    }

    /// The value as ISO 8601 if this is a date column and the value looks like a date.
    func isoDate(_ value: SQLiteValue) -> String? {
        guard isDate else { return nil }
        return switch value {
        case .integer(let number): SQLiteDates.iso(number: Double(number), coreData: isCoreData, dateOnly: isDateOnly)
        case .real(let number, _): SQLiteDates.iso(number: number, coreData: isCoreData, dateOnly: isDateOnly)
        case .text(let text): SQLiteDates.iso(text: text, coreData: isCoreData, dateOnly: isDateOnly)
        case .null, .blob: nil
        }
    }
}

/// Stores a large blob as a file and returns the path it appears under, relative to the
/// volume. Called with the blob, its row number and its column, possibly several times for
/// the same blob (CSV measures first, JSON shows it too); it's stored once.
typealias SQLiteBlobFile = (_ data: Data, _ row: Int, _ column: String) throws -> String

/// One table or view, in the forms Zippy shows it: CSV, JSON and SQL.
///
/// Every output is a fresh `SELECT *`, so only one row at a time is in memory. Row numbers
/// (1, 2, …) follow that order, which is the same each time for an unchanged database.
struct SQLiteTable {
    let database: SQLiteDatabase
    let name: String
    let isCoreData: Bool

    /// Blobs up to this size are shown inline as hex (UUIDs, hashes); larger ones get a file.
    static let inlineBlobSize = 32

    private var select: String { "SELECT * FROM \(SQLiteDatabase.quote(name))" }

    func columns() throws -> [SQLiteColumn] {
        let statement = try database.prepare(select)
        defer { sqlite3_finalize(statement) }
        return (0..<sqlite3_column_count(statement)).map { column in
            SQLiteColumn(name: sqlite3_column_name(statement, column).map { String(cString: $0) } ?? "",
                         declaredType: sqlite3_column_decltype(statement, column).map { String(cString: $0) },
                         isCoreData: isCoreData)
        }
    }

    /// Calls `body` with every row; returns the number of rows.
    @discardableResult
    func forEachRow(_ body: (_ row: Int, _ values: [SQLiteValue]) throws -> Void) throws -> Int {
        let statement = try database.prepare(select)
        defer { sqlite3_finalize(statement) }
        let count = sqlite3_column_count(statement)
        var row = 0
        while try database.step(statement) {
            row += 1
            try body(row, (0..<count).map { Self.value(statement, $0) })
        }
        return row
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column),
                         sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
        }
    }

    /// Text for CSV and JSON; `nil` for NULL.
    static func text(_ value: SQLiteValue, in column: SQLiteColumn, row: Int,
                     blobFile: SQLiteBlobFile) throws -> String? {
        if let date = column.isoDate(value) { return date }
        switch value {
        case .null: return nil
        case .integer(let number): return String(number)
        case .real(_, let text): return text
        case .text(let text): return text
        case .blob(let data):
            guard data.count > inlineBlobSize else { return SQLiteSQL.hex(data) }
            return try blobFile(data, row, column.name)
        }
    }

    // MARK: CSV

    /// CSV whose columns line up: every cell is padded to the widest cell of its column.
    /// The padding goes after the value, before the comma, because Excel only recognizes a
    /// quoted field when the quote follows the comma directly. Starts with a UTF-8 byte order
    /// mark, which Excel needs to read UTF-8. Two passes: measure, then write.
    func writeCSV(to handle: FileHandle, blobFile: SQLiteBlobFile) throws -> Int {
        let columns = try columns()
        var widths = columns.map { SQLiteCSV.width(SQLiteCSV.quote($0.name)) }
        try forEachRow { row, values in
            for (index, value) in values.enumerated() {
                let cell = SQLiteCSV.quote(try Self.text(value, in: columns[index], row: row, blobFile: blobFile) ?? "")
                widths[index] = max(widths[index], SQLiteCSV.width(cell))
            }
        }

        var output = SQLiteOutput(handle: handle)
        output.write("\u{FEFF}" + SQLiteCSV.line(columns.map { SQLiteCSV.quote($0.name) }, widths: widths))
        let rows = try forEachRow { row, values in
            let cells = try values.enumerated().map { index, value in
                SQLiteCSV.quote(try Self.text(value, in: columns[index], row: row, blobFile: blobFile) ?? "")
            }
            output.write(SQLiteCSV.line(cells, widths: widths))
            try output.flushIfLarge()
        }
        try output.flush()
        return rows
    }

    // MARK: JSON

    /// An array with one object per row, one row per line. Dates as ISO text, large blobs
    /// as the path of their file, short ones as hex.
    func writeJSON(to handle: FileHandle, blobFile: SQLiteBlobFile) throws {
        let columns = try columns()
        let keys = columns.map { SQLiteJSON.string($0.name) + ": " }
        var output = SQLiteOutput(handle: handle)
        output.write("[")
        let rows = try forEachRow { row, values in
            let fields = try values.enumerated().map { index, value in
                keys[index] + (try Self.json(value, in: columns[index], row: row, blobFile: blobFile))
            }
            output.write((row == 1 ? "\n  {" : ",\n  {") + fields.joined(separator: ", ") + "}")
            try output.flushIfLarge()
        }
        output.write(rows == 0 ? "]\n" : "\n]\n")
        try output.flush()
    }

    private static func json(_ value: SQLiteValue, in column: SQLiteColumn, row: Int,
                             blobFile: SQLiteBlobFile) throws -> String {
        if let date = column.isoDate(value) { return SQLiteJSON.string(date) }
        switch value {
        case .null: return "null"
        case .integer(let number): return String(number)
        case .real(let number, let text): return number.isFinite ? text : "null"
        case .text(let text): return SQLiteJSON.string(text)
        case .blob: return SQLiteJSON.string(try text(value, in: column, row: row, blobFile: blobFile) ?? "")
        }
    }

    // MARK: SQL

    /// `INSERT` statements for every row, as `sqlite3 .dump` writes them: exact values,
    /// no date conversion, blobs as hex.
    func writeInserts(to output: inout SQLiteOutput) throws {
        let target = SQLiteDatabase.quote(name)
        try forEachRow { _, values in
            output.write("INSERT INTO \(target) VALUES(" + values.map(SQLiteSQL.literal).joined(separator: ",") + ");\n")
            try output.flushIfLarge()
        }
    }
}

/// Buffered UTF-8 output to a file.
struct SQLiteOutput {
    let handle: FileHandle
    private var buffer = ""

    init(handle: FileHandle) { self.handle = handle }

    mutating func write(_ text: String) { buffer += text }

    mutating func flushIfLarge() throws {
        if buffer.utf8.count > 1 << 16 { try flush() }
    }

    mutating func flush() throws {
        try handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
    }
}

// MARK: - Formats

enum SQLiteCSV {
    /// RFC 4180 quoting. Surrounding spaces are quoted too, since padding adds spaces.
    static func quote(_ value: String) -> String {
        let needsQuotes = value.contains { $0 == "," || $0 == "\"" || $0.isNewline }
            || value.first == " " || value.last == " "
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Cells padded to `widths` and joined by commas; the last cell isn't padded.
    static func line(_ cells: [String], widths: [Int]) -> String {
        var line = ""
        for (index, cell) in cells.enumerated() {
            line += cell
            if index < cells.count - 1 {
                line += String(repeating: " ", count: max(0, widths[index] - width(cell))) + ","
            }
        }
        return line + "\n"
    }

    /// Width in a monospaced font: East Asian wide characters and most emoji take two
    /// columns, everything else one.
    static func width(_ text: String) -> Int {
        text.reduce(0) { total, character in
            total + (character.unicodeScalars.contains(where: isWide) ? 2 : 1)
        }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            true
        default:
            false
        }
    }
}

enum SQLiteJSON {
    static func string(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

enum SQLiteSQL {
    static func hex(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02X", $0) }.joined() + "'"
    }

    /// The value as an SQL literal that reads back exactly.
    static func literal(_ value: SQLiteValue) -> String {
        switch value {
        case .null: "NULL"
        case .integer(let number): String(number)
        case .real(let number, let text):
            number.isFinite ? text : (number > 0 ? "1e999" : number < 0 ? "-1e999" : "NULL")
        case .text(let text): "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        case .blob(let data): hex(data)
        }
    }
}

enum SQLiteDates {
    private static let julianDays: ClosedRange<Double> = 1_721_059.5...5_373_484.5   // years 0 to 9999
    private static let unixJulianDay = 2_440_587.5

    /// A number in a date column as ISO 8601 (UTC). Which epoch it counts from is guessed
    /// from its size: Julian day, Unix seconds, milliseconds or microseconds, or for Core
    /// Data seconds since 2001.
    static func iso(number: Double, coreData: Bool, dateOnly: Bool) -> String? {
        guard number.isFinite else { return nil }
        let date: Date
        if coreData {
            date = Date(timeIntervalSinceReferenceDate: number)
        } else if julianDays.contains(number) {
            date = Date(timeIntervalSince1970: (number - unixJulianDay) * 86_400)
        } else if abs(number) >= 1e14 {
            date = Date(timeIntervalSince1970: number / 1e6)
        } else if abs(number) >= 1e11 {
            date = Date(timeIntervalSince1970: number / 1e3)
        } else {
            date = Date(timeIntervalSince1970: number)
        }
        return iso(date, dateOnly: dateOnly)
    }

    /// Text in a date column as ISO 8601. ISO-like text ("2024-03-01 12:30:00") only gets the
    /// "T"; a few other common forms are converted; anything else stays as it is (`nil`).
    static func iso(text: String, coreData: Bool, dateOnly: Bool) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Timestamps stored as text; short numbers like "2024" are more likely a year
        if let number = Double(trimmed), abs(number) >= 1e6 {
            return iso(number: number, coreData: coreData, dateOnly: dateOnly)
        }
        if let match = trimmed.wholeMatch(of: isoLike) {
            let (_, day, time, zone) = match.output
            guard let time else { return String(day) }
            return "\(day)T\(time)\(zone ?? "")"
        }
        for format in otherFormats {
            if let date = format.formatter.date(from: trimmed) {
                return iso(date, dateOnly: !format.hasTime)
            }
        }
        return nil
    }

    private nonisolated(unsafe) static let isoLike =
        /(\d{4}-\d{2}-\d{2})(?:[ T](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?))?(Z|[+-]\d{2}:?\d{2})?/

    private struct OtherFormat {
        let formatter: DateFormatter
        let hasTime: Bool
    }

    private nonisolated(unsafe) static let otherFormats: [OtherFormat] = [
        ("dd.MM.yyyy HH:mm:ss", true), ("dd.MM.yyyy HH:mm", true), ("dd.MM.yyyy", false),
        ("yyyy/MM/dd HH:mm:ss", true), ("yyyy/MM/dd", false),
    ].map { pattern, hasTime in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return OtherFormat(formatter: formatter, hasTime: hasTime)
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso(_ date: Date, dateOnly: Bool) -> String {
        let seconds = date.timeIntervalSince1970
        let text = (seconds.rounded(.down) == seconds ? isoFormatter : isoFractionalFormatter).string(from: date)
        if dateOnly, text.hasSuffix("T00:00:00Z") { return String(text.prefix(10)) }
        return text
    }
}
