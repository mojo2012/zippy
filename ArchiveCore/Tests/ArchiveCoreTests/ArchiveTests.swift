import Foundation
import Testing
@testable import ArchiveCore

/// Reading ZIPs. Test ZIPs are built at runtime with /usr/bin/zip or python3.
@Suite struct ArchiveTests {
    let dir: URL

    init() throws {
        dir = try makeTempDir("archive")
    }

    // MARK: Helpers

    /// Builds a ZIP with arbitrary (including unsafe) paths via Python.
    private func makeRawZip(_ name: String, entries: [String: String]) throws -> URL {
        let zip = dir.appendingPathComponent(name)
        let pairs = entries.map { "(\(pyString($0.key)), \(pyString($0.value)))" }.joined(separator: ", ")
        let script = """
        import zipfile
        with zipfile.ZipFile(\(pyString(zip.path)), "w") as z:
            for name, data in [\(pairs)]:
                z.writestr(name, data)
        """
        try run("/usr/bin/python3", ["-I", "-c", script], in: dir)
        return zip
    }

    private func pyString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: Tests

    @Test func listsFilesAndCreatesMissingDirectories() throws {
        // -D: no directory entries in the ZIP, like many tools produce
        let zip = try makeZip(in: dir, [
            "readme.txt": Data("hi".utf8),
            "a/b/c.txt": Data("deep".utf8),
            "a/x.txt": Data("x".utf8),
        ], flags: ["-D"])
        let index = try Archive(url: zip).index

        #expect(index.children(of: ArchiveIndex.rootID).map(\.name) == ["a", "readme.txt"])
        let a = try #require(index.lookup(path: "a"))
        #expect(a.isDirectory)
        #expect(index.children(of: a.id).map(\.name) == ["b", "x.txt"])
        let c = try #require(index.lookup(path: "a/b/c.txt"))
        #expect(c.kind == .file)
        #expect(c.size == 4)
        #expect(index.entry(c.parentID)?.name == "b")
    }

    @Test func readsWholeFilesAndRanges() throws {
        let big = randomData(1_500_000)
        let zip = try makeZip(in: dir, ["big.bin": big, "small.txt": Data("hello".utf8)])
        let archive = try Archive(url: zip)
        let entry = try #require(archive.index.lookup(path: "big.bin"))

        #expect(try archive.contents(of: entry.id) == big)
        #expect(try archive.read(entry.id, offset: 1_000_000, length: 4096) == big[1_000_000..<1_004_096])
        // past the end: only the remainder
        #expect(try archive.read(entry.id, offset: 1_499_990, length: 100) == big[1_499_990...])
        #expect(try archive.read(entry.id, offset: 2_000_000, length: 10).isEmpty)
        #expect(try archive.text(at: "small.txt") == "hello")
    }

    @Test func readsConcurrently() async throws {
        let big = randomData(800_000)
        let zip = try makeZip(in: dir, ["big.bin": big])
        let archive = try Archive(url: zip)
        let id = try #require(archive.index.lookup(path: "big.bin")).id

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let offset = i * 50_000
                    let data = try archive.read(id, offset: UInt64(offset), length: 50_000)
                    #expect(data == big[offset..<offset + 50_000])
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func handlesEmptyFilesAndUnicodeNames() throws {
        let zip = try makeZip(in: dir, [
            "Grüße/Ärger.txt": Data("ä".utf8),
            "empty.txt": Data(),
        ])
        let archive = try Archive(url: zip)
        let file = try #require(archive.index.lookup(path: "Grüße/Ärger.txt"))
        #expect(try archive.contents(of: file.id) == Data("ä".utf8))
        // the decomposed spelling (as sent by Finder) finds the same entry
        let decomposed = "Grüße/Ärger.txt".decomposedStringWithCanonicalMapping
        #expect(archive.index.lookup(path: decomposed)?.id == file.id)
        let empty = try #require(archive.index.lookup(path: "empty.txt"))
        #expect(empty.size == 0)
        #expect(try archive.contents(of: empty.id).isEmpty)
    }

    @Test func keepsSymlinks() throws {
        // -y: store links as links instead of following them
        let zip = try makeZip(in: dir, ["target.txt": Data("t".utf8)], flags: ["-y"]) { src in
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path,
                                                       withDestinationPath: "target.txt")
        }
        let link = try #require(try Archive(url: zip).index.lookup(path: "link"))
        #expect(link.kind == .symlink)
        #expect(link.symlinkTarget == "target.txt")
    }

    @Test func dropsUnsafePaths() throws {
        let zip = try makeRawZip("evil.zip", entries: [
            "../escape.txt": "evil",
            "a/../../also.txt": "evil",
            "/absolute.txt": "ok",
            "./normal.txt": "ok",
        ])
        let names = try Archive(url: zip).index.children(of: ArchiveIndex.rootID).map(\.name)
        #expect(names == ["absolute.txt", "normal.txt"])
    }

    @Test func laterDuplicateWins() throws {
        let zip = try makeRawZip("dup.zip", entries: ["d.txt": "x"])
        // Python dictionaries can't hold the duplicate; append it separately
        try run("/usr/bin/python3", ["-I", "-c", """
            import zipfile, warnings
            warnings.simplefilter("ignore")
            with zipfile.ZipFile(\(pyString(zip.path)), "a") as z:
                z.writestr("d.txt", "new")
            """], in: dir)
        let archive = try Archive(url: zip)
        #expect(archive.index.children(of: ArchiveIndex.rootID).count == 1)
        #expect(try archive.text(at: "d.txt") == "new")
    }

    @Test func rejectsNonZipFiles() throws {
        let file = dir.appendingPathComponent("not.zip")
        try Data("this is not a zip".utf8).write(to: file)
        #expect(throws: ArchiveError.self) { try Archive(url: file) }
    }

    @Test func closeRemovesCache() throws {
        let zip = try makeZip(in: dir, ["f.txt": Data("cache".utf8)])
        let archive = try Archive(url: zip)
        let id = try #require(archive.index.lookup(path: "f.txt")).id
        _ = try archive.contents(of: id)
        archive.close()
        // after close() the entry is extracted again on demand
        #expect(try archive.contents(of: id) == Data("cache".utf8))
    }
}
