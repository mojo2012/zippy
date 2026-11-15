import Foundation
import Testing
@testable import ArchiveCore

/// Geteilte Archive: mehrteilige RAR (RAR4, RAR5) und zerschnittene Dateien (`.7z.001` …).
@Suite struct SplitArchiveTests {
    let dir: URL
    let big = Data((0..<300_000).map { UInt8(($0 * 13) % 251) })

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-split-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
    }

    private func text(_ archive: Archive, _ path: String) throws -> Data? {
        guard let entry = archive.index.lookup(path: path) else { return nil }
        return try archive.contents(of: entry.id)
    }

    /// Dieselbe HTML-Datei liegt auch im ungeteilten RAR-Testarchiv.
    private func referenceHTML() throws -> Data {
        let archive = try Archive(url: fixture("rar_compress_normal"))
        return try #require(try text(archive, "LibarchiveAddingTest.html"))
    }

    @Test(arguments: [1, 3, 6])
    func rar4MultiVolumeFromAnyPart(_ part: Int) throws {
        let archive = try Archive(url: fixture("rar4_multivolume.part\(part)"))
        #expect(archive.format == .rar)
        #expect(archive.parts.count == 6)
        #expect(archive.parts.first?.lastPathComponent == "rar4_multivolume.part1.rar")
        let html = try referenceHTML()
        #expect(try text(archive, "LibarchiveAddingTest.html") == html)
        #expect(try text(archive, "LibarchiveAddingTest2.html")?.count == html.count)
        #expect(!archive.canSave)
    }

    /// Altes RAR-Namensschema: Name.rar, Name.r00, Name.r01 …
    @Test func rar4OldNaming() throws {
        for part in 1...6 {
            let name = part == 1 ? "Alt.rar" : "Alt.r\(String(format: "%02d", part - 2))"
            try FileManager.default.copyItem(at: fixture("rar4_multivolume.part\(part)"),
                                             to: dir.appendingPathComponent(name))
        }
        let archive = try Archive(url: dir.appendingPathComponent("Alt.r02"))
        #expect(archive.parts.map(\.lastPathComponent) == ["Alt.rar", "Alt.r00", "Alt.r01", "Alt.r02", "Alt.r03", "Alt.r04"])
        #expect(try text(archive, "LibarchiveAddingTest.html") == referenceHTML())
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Alt.r02")) == "Alt")
    }

    /// Solides RAR5 über vier Teile. (7-Zip aus Homebrew hat keinen RAR-Entpacker,
    /// taugt also nicht als Vergleich.)
    @Test func rar5SolidMultiVolume() throws {
        let first = try fixture("rar5_multivolume_solid.part01")
        let archive = try Archive(url: first)
        #expect(archive.parts.count == 4)
        let names = Set(archive.index.entries.values.filter { $0.kind == .file }.map(\.name))
        #expect(names.isSuperset(of: ["cebula.txt", "test.bin", "test1.bin", "test2.bin"]))
        for entry in archive.index.entries.values where entry.kind == .file {
            #expect(try archive.contents(of: entry.id).count == Int(entry.size), "\(entry.name)")
        }

        // libarchive prüft beim Entpacken die RAR5-Prüfsummen selbst
        let poem = String(decoding: try #require(try text(archive, "cebula.txt")), as: UTF8.self)
        #expect(poem.hasPrefix("Cebula"))
    }

    /// 7z, in Stücke zerschnitten wie von 7-Zip ("Name.7z.001", ".002" …).
    private func makeSplit7z(chunk: Int = 40_000) throws -> [URL] {
        let src = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try big.write(to: src.appendingPathComponent("big.bin"))
        try Data("klein".utf8).write(to: src.appendingPathComponent("klein.txt"))
        let whole = dir.appendingPathComponent("ganz.7z")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--format", "7zip", "--options", "7zip:compression=store", "-cf", whole.path, "-C", src.path, "."]
        try tar.run()
        tar.waitUntilExit()
        let data = try Data(contentsOf: whole)
        var parts: [URL] = []
        for (index, start) in stride(from: 0, to: data.count, by: chunk).enumerated() {
            let part = dir.appendingPathComponent("Fotos.7z." + String(format: "%03d", index + 1))
            try data[start..<min(start + chunk, data.count)].write(to: part)
            parts.append(part)
        }
        #expect(parts.count >= 3)
        return parts
    }

    @Test func split7z() throws {
        let parts = try makeSplit7z()
        let archive = try Archive(url: parts[1])   // irgendein Teil
        #expect(archive.format == .sevenZip)
        #expect(archive.parts == parts)
        #expect(try text(archive, "big.bin") == big)
        #expect(try text(archive, "klein.txt") == Data("klein".utf8))
        #expect(!archive.canSave)
        #expect(EditableArchive(archive: archive).isReadOnly)
        #expect(Archive.volumeName(for: parts[0]) == "Fotos")
        #expect(ArchiveParts.firstPart(of: parts.last!) == parts[0])
    }

    @Test func missingPartIsReported() throws {
        let parts = try makeSplit7z()
        try FileManager.default.removeItem(at: parts[2])
        // Meldung ist übersetzt; der fehlende Teil steht in jeder Sprache drin
        do {
            _ = try Archive(url: parts[0])
            Issue.record("Fehlender Teil nicht bemerkt")
        } catch ArchiveError.openFailed(let reason) {
            #expect(reason.contains("Fotos.7z.003"))
        }
    }

    @Test func ordinaryNamesAreNotParts() throws {
        for name in ["a.rar", "a.zip", "a.tar.gz", "part1.zip", "Bericht 2024.pdf.zip"] {
            #expect(try ArchiveParts.parts(for: dir.appendingPathComponent(name)) == nil, "\(name)")
        }
        #expect(Archive.isSplitZip(dir.appendingPathComponent("a.z01")))
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Fotos.part01.rar")) == "Fotos")
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Quellen.tar.gz.001")) == "Quellen")
    }
}
