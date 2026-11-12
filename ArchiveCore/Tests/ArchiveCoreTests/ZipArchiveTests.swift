import Foundation
import Testing
@testable import ArchiveCore

/// Test-ZIPs werden zur Laufzeit mit /usr/bin/zip bzw. python3 erzeugt.
@Suite struct ZipArchiveTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Hilfen

    /// Legt Dateien in `src/` an und packt sie mit `zip <flags>` nach `name`.
    private func makeZip(_ name: String, flags: [String] = ["-r"],
                         files: [String: Data], symlinks: [String: String] = [:]) throws -> URL {
        let src = dir.appendingPathComponent("src-\(name)", isDirectory: true)
        for (path, data) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        for (path, target) in symlinks {
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent(path).path,
                                                       withDestinationPath: target)
        }
        let zip = dir.appendingPathComponent(name)
        try run("/usr/bin/zip", flags + ["-q", zip.path, "."], in: src)
        return zip
    }

    /// Baut ein ZIP mit frei wählbaren Pfaden (auch unsicheren) über Python.
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

    private func run(_ tool: String, _ args: [String], in cwd: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = cwd
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(tool) fehlgeschlagen")
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: Tests

    @Test func listsFilesAndCreatesMissingDirectories() throws {
        // -D: keine Ordner-Einträge im ZIP, wie bei vielen Werkzeugen
        let zip = try makeZip("tree.zip", flags: ["-r", "-D"], files: [
            "readme.txt": Data("hi".utf8),
            "a/b/c.txt": Data("tief".utf8),
            "a/x.txt": Data("x".utf8),
        ])
        let archive = try ZipArchive(url: zip)
        let index = archive.index

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
        let zip = try makeZip("data.zip", files: ["big.bin": big, "small.txt": Data("hallo".utf8)])
        let archive = try ZipArchive(url: zip)
        let entry = try #require(archive.index.lookup(path: "big.bin"))

        #expect(try archive.contents(of: entry.id) == big)
        #expect(try archive.read(entry.id, offset: 1_000_000, length: 4096) == big[1_000_000..<1_004_096])
        // über das Ende hinaus: nur der Rest
        #expect(try archive.read(entry.id, offset: 1_499_990, length: 100) == big[1_499_990...])
        #expect(try archive.read(entry.id, offset: 2_000_000, length: 10).isEmpty)

        let small = try #require(archive.index.lookup(path: "small.txt"))
        #expect(String(decoding: try archive.contents(of: small.id), as: UTF8.self) == "hallo")
    }

    @Test func readsConcurrently() async throws {
        let big = randomData(800_000)
        let zip = try makeZip("parallel.zip", files: ["big.bin": big])
        let archive = try ZipArchive(url: zip)
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
        let zip = try makeZip("unicode.zip", files: [
            "Grüße/Ärger.txt": Data("ä".utf8),
            "leer.txt": Data(),
        ])
        let archive = try ZipArchive(url: zip)
        let file = try #require(archive.index.lookup(path: "Grüße/Ärger.txt"))
        #expect(try archive.contents(of: file.id) == Data("ä".utf8))
        let empty = try #require(archive.index.lookup(path: "leer.txt"))
        #expect(empty.size == 0)
        #expect(try archive.contents(of: empty.id).isEmpty)
    }

    @Test func keepsSymlinks() throws {
        // -y: Links als Links speichern statt ihnen zu folgen
        let zip = try makeZip("links.zip", flags: ["-r", "-y"],
                              files: ["ziel.txt": Data("z".utf8)], symlinks: ["link": "ziel.txt"])
        let archive = try ZipArchive(url: zip)
        let link = try #require(archive.index.lookup(path: "link"))
        #expect(link.kind == .symlink)
        #expect(link.symlinkTarget == "ziel.txt")
    }

    @Test func dropsUnsafePaths() throws {
        let zip = try makeRawZip("evil.zip", entries: [
            "../ausbruch.txt": "böse",
            "a/../../auch.txt": "böse",
            "/absolut.txt": "ok",
            "./normal.txt": "ok",
        ])
        let archive = try ZipArchive(url: zip)
        let names = archive.index.children(of: ArchiveIndex.rootID).map(\.name)
        #expect(names == ["absolut.txt", "normal.txt"])
    }

    @Test func laterDuplicateWins() throws {
        let zip = try makeRawZip("dup.zip", entries: ["d.txt": "x"])
        // Python ordnet Dictionaries nicht garantiert; Duplikat einzeln anhängen
        try run("/usr/bin/python3", ["-I", "-c", """
            import zipfile, warnings
            warnings.simplefilter("ignore")
            with zipfile.ZipFile(\(pyString(zip.path)), "a") as z:
                z.writestr("d.txt", "neu")
            """], in: dir)
        let archive = try ZipArchive(url: zip)
        #expect(archive.index.children(of: ArchiveIndex.rootID).count == 1)
        let entry = try #require(archive.index.lookup(path: "d.txt"))
        #expect(try archive.contents(of: entry.id) == Data("neu".utf8))
    }

    @Test func rejectsNonZipFiles() throws {
        let file = dir.appendingPathComponent("kein.zip")
        try Data("das ist kein zip".utf8).write(to: file)
        #expect(throws: ArchiveError.self) { try ZipArchive(url: file) }
    }

    @Test func closeRemovesCache() throws {
        let zip = try makeZip("cache.zip", files: ["f.txt": Data("cache".utf8)])
        let archive = try ZipArchive(url: zip)
        let id = try #require(archive.index.lookup(path: "f.txt")).id
        _ = try archive.contents(of: id)
        archive.close()
        // nach close() wird bei Bedarf neu entpackt
        #expect(try archive.contents(of: id) == Data("cache".utf8))
    }
}
