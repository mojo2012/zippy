import Foundation
import Testing
@testable import ArchiveCore

/// SQLite databases, shown as CSV, JSON, DDL, blob files, schema, dump and info.
@Suite struct SQLiteTests {
    let dir: URL
    /// CSV files start with a UTF-8 byte order mark for Excel.
    let bom = "\u{FEFF}"

    init() throws {
        dir = try makeTempDir("sqlite")
    }

    /// A database built with the system's sqlite3 tool.
    private func makeDatabase(_ sql: String, name: String = "test.db") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try run("/usr/bin/sqlite3", [url.path, sql])
        return url
    }

    @Test func tablesAndViewsBecomeFiles() throws {
        let url = try makeDatabase("""
            CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE INDEX people_name ON people(name);
            CREATE TRIGGER people_check BEFORE INSERT ON people BEGIN SELECT 1; END;
            CREATE VIEW grown_ups AS SELECT name FROM people;
            INSERT INTO people(name) VALUES ('Alice');
            """)
        let archive = try Archive(url: url)
        #expect(archive.format == .sqlite)
        let names = archive.index.children(of: ArchiveIndex.rootID).map(\.name).sorted()
        #expect(names == ["_dump.sql", "_info.txt", "_schema.sql", "grown_ups", "people"])
        let people = try #require(archive.index.lookup(path: "people"))
        #expect(archive.index.children(of: people.id).map(\.name).sorted() == ["people.csv", "people.ddl", "people.json"])

        let ddl = try #require(try archive.text(at: "people/people.ddl"))
        #expect(ddl.hasPrefix("CREATE TABLE people(id INTEGER PRIMARY KEY, name TEXT NOT NULL);\n"))
        #expect(ddl.contains("CREATE INDEX people_name ON people(name);"))
        #expect(ddl.contains("CREATE TRIGGER people_check"))
        #expect(try archive.text(at: "grown_ups/grown_ups.ddl") == "CREATE VIEW grown_ups AS SELECT name FROM people;\n")
        #expect(try archive.text(at: "grown_ups/grown_ups.csv") == bom + "name\nAlice\n")
        #expect(try archive.text(at: "grown_ups/grown_ups.json") == "[\n  {\"name\": \"Alice\"}\n]\n")
    }

    @Test func columnsAreAlignedAndQuoted() throws {
        let url = try makeDatabase("""
            CREATE TABLE people(id INTEGER, name TEXT, born DATE, note TEXT);
            INSERT INTO people VALUES (1, 'Alice', '1990-05-17', NULL);
            INSERT INTO people VALUES (2, 'Bob, Jr.', '2001-01-02', 'say "hi"');
            """)
        let csv = try #require(try Archive(url: url).text(at: "people/people.csv"))
        // Padding before the comma: Excel only sees a quoted field right after a comma
        let expected = [
            #"id,name      ,born      ,note"#,
            #"1 ,Alice     ,1990-05-17,"#,
            #"2 ,"Bob, Jr.",2001-01-02,"say ""hi""""#,
        ]
        #expect(csv == bom + expected.joined(separator: "\n") + "\n")
    }

    /// No limit: the widest cell sets the width, however long.
    @Test func longCellsAreNotLimited() throws {
        let long = String(repeating: "x", count: 500)
        let url = try makeDatabase("CREATE TABLE t(a, b); INSERT INTO t VALUES ('\(long)', 1), ('y', 2);")
        let lines = try #require(try Archive(url: url).text(at: "t/t.csv")).split(separator: "\n")
        #expect(lines[1] == "\(long),1")
        #expect(lines[2] == "y" + String(repeating: " ", count: 499) + ",2")
    }

    @Test func datesAreISO() throws {
        let url = try makeDatabase("""
            CREATE TABLE events(text DATETIME, unix TIMESTAMP, julian DATE, millis DATETIME, other DATETIME, plain INTEGER);
            INSERT INTO events VALUES ('2024-03-01 12:30:00', 1700000000, 2460000.5, 1700000000123, 'not a date', 1700000000);
            """)
        let archive = try Archive(url: url)
        let csv = try #require(try archive.text(at: "events/events.csv"))
        let row = csv.split(separator: "\n")[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(row == ["2024-03-01T12:30:00", "2023-11-14T22:13:20Z", "2023-02-25",
                        "2023-11-14T22:13:20.123Z", "not a date", "1700000000"])
        let json = try #require(try archive.text(at: "events/events.json"))
        #expect(json.contains(#""unix": "2023-11-14T22:13:20Z""#))
        #expect(json.contains(#""plain": 1700000000"#))
    }

    /// Core Data counts seconds from 2001.
    @Test func coreDataDates() throws {
        let url = try makeDatabase("""
            CREATE TABLE Z_METADATA(Z_VERSION INTEGER);
            CREATE TABLE ZNOTE(ZDATE TIMESTAMP);
            INSERT INTO ZNOTE VALUES (0), (86400.5);
            """)
        let csv = try #require(try Archive(url: url).text(at: "ZNOTE/ZNOTE.csv"))
        #expect(csv == bom + "ZDATE\n2001-01-01T00:00:00Z\n2001-01-02T00:00:00.500Z\n")
    }

    /// Short blobs inline as hex, large ones as files with an extension from their content.
    @Test func blobs() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 7, count: 100))
        let pngHex = png.map { String(format: "%02X", $0) }.joined()
        let url = try makeDatabase("""
            CREATE TABLE data(small BLOB, big BLOB, empty TEXT);
            INSERT INTO data VALUES (X'00FF10', X'\(pngHex)', NULL);
            INSERT INTO data VALUES (NULL, zeroblob(40), NULL);
            """)
        let archive = try Archive(url: url)
        #expect(try archive.data(at: "data/blobs/1-big.png") == png)
        #expect(try archive.data(at: "data/blobs/2-big.bin") == Data(count: 40))
        let csv = try #require(try archive.text(at: "data/data.csv"))
        #expect(csv == bom + "small    ,big            ,empty\n"
                + "X'00FF10',blobs/1-big.png,\n"
                + "         ,blobs/2-big.bin,\n")
        let json = try #require(try archive.text(at: "data/data.json"))
        #expect(json == """
            [
              {"small": "X'00FF10'", "big": "blobs/1-big.png", "empty": null},
              {"small": null, "big": "blobs/2-big.bin", "empty": null}
            ]

            """)
    }

    /// The dump reads back into an identical database.
    @Test func dumpRestoresTheDatabase() throws {
        let url = try makeDatabase("""
            CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, amount REAL, data BLOB);
            CREATE INDEX t_name ON t(name);
            CREATE VIEW v AS SELECT name FROM t;
            INSERT INTO t(name, amount, data) VALUES ('it''s', 0.1, X'00'), ('Grüße', -2.5e300, NULL), (NULL, 3, zeroblob(50));
            """)
        let dump = try #require(try Archive(url: url).text(at: "_dump.sql"))
        let copy = dir.appendingPathComponent("copy.db")
        try run("/usr/bin/sqlite3", [copy.path, dump])
        #expect(try run("/usr/bin/sqlite3", [copy.path, ".dump"]) == run("/usr/bin/sqlite3", [url.path, ".dump"]))
    }

    @Test func schemaAndInfo() throws {
        let url = try makeDatabase("""
            PRAGMA user_version = 7;
            CREATE TABLE a(id INTEGER PRIMARY KEY);
            CREATE TABLE b(a_id REFERENCES a(id));
            INSERT INTO a VALUES (1), (2);
            """)
        let archive = try Archive(url: url)
        #expect(try archive.text(at: "_schema.sql") == """
            CREATE TABLE a(id INTEGER PRIMARY KEY);
            CREATE TABLE b(a_id REFERENCES a(id));

            """)
        let info = try #require(try archive.text(at: "_info.txt"))
        #expect(info.contains("User version     7"))
        #expect(info.contains("a  2 rows, 1 columns"))
        #expect(info.contains("b  0 rows, 1 columns, references a"))
    }

    /// "/" can't be in a file name. SQLite names are case-insensitive, so after replacing
    /// it two tables can end up with the same file name.
    @Test func slashesInNames() throws {
        let url = try makeDatabase(#"CREATE TABLE "a/b"(x); CREATE TABLE "a∕b"(y);"#)
        let names = Set(try Archive(url: url).index.children(of: ArchiveIndex.rootID).map(\.name))
        #expect(names.isSuperset(of: ["a∕b", "a∕b (2)"]))
        #expect(try Archive(url: url).index.lookup(path: "a∕b (2)/a∕b (2).csv") != nil)
    }

    @Test func isReadOnly() throws {
        let url = try makeDatabase("CREATE TABLE t(x); INSERT INTO t VALUES (1);")
        let before = try Data(contentsOf: url)
        let archive = try Archive(url: url)
        #expect(!archive.canSave)
        #expect(!archive.needsPassword)
        #expect(EditableArchive(archive: archive).isReadOnly)
        #expect(try archive.text(at: "t/t.csv") == bom + "x\n1\n")
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func cellWidthCountsWideCharacters() {
        #expect(SQLiteCSV.width("abc") == 3)
        #expect(SQLiteCSV.width("日本") == 4)
        #expect(SQLiteCSV.width("Grüße") == 5)
    }
}
