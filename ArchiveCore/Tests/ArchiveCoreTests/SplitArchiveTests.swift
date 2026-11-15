import Foundation
import Testing
@testable import ArchiveCore

/// Split archives: multi-volume RAR (RAR4, RAR5) and cut-up files (`.7z.001` …).
@Suite struct SplitArchiveTests {
    let dir: URL
    let big = Data((0..<300_000).map { UInt8(($0 * 13) % 251) })

    init() throws {
        dir = try makeTempDir("split")
    }

    /// The same HTML file is also in the single-volume RAR test archive.
    private func referenceHTML() throws -> Data {
        try #require(try Archive(url: fixture("rar_compress_normal")).data(at: "LibarchiveAddingTest.html"))
    }

    @Test(arguments: [1, 3, 6])
    func rar4MultiVolumeFromAnyPart(_ part: Int) throws {
        let archive = try Archive(url: fixture("rar4_multivolume.part\(part)"))
        #expect(archive.format == .rar)
        #expect(archive.parts.count == 6)
        #expect(archive.parts.first?.lastPathComponent == "rar4_multivolume.part1.rar")
        let html = try referenceHTML()
        #expect(try archive.data(at: "LibarchiveAddingTest.html") == html)
        #expect(try archive.data(at: "LibarchiveAddingTest2.html")?.count == html.count)
        #expect(!archive.canSave)
    }

    /// Old RAR naming scheme: Name.rar, Name.r00, Name.r01 …
    @Test func rar4OldNaming() throws {
        for part in 1...6 {
            let name = part == 1 ? "Old.rar" : "Old.r\(String(format: "%02d", part - 2))"
            try FileManager.default.copyItem(at: fixture("rar4_multivolume.part\(part)"),
                                             to: dir.appendingPathComponent(name))
        }
        let archive = try Archive(url: dir.appendingPathComponent("Old.r02"))
        #expect(archive.parts.map(\.lastPathComponent) == ["Old.rar", "Old.r00", "Old.r01", "Old.r02", "Old.r03", "Old.r04"])
        #expect(try archive.data(at: "LibarchiveAddingTest.html") == referenceHTML())
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Old.r02")) == "Old")
    }

    /// Solid RAR5 across four parts. (Homebrew's 7-Zip has no RAR extractor,
    /// so it can't serve as a reference.)
    @Test func rar5SolidMultiVolume() throws {
        let archive = try Archive(url: fixture("rar5_multivolume_solid.part01"))
        #expect(archive.parts.count == 4)
        let names = Set(archive.index.entries.values.filter { $0.kind == .file }.map(\.name))
        #expect(names.isSuperset(of: ["cebula.txt", "test.bin", "test1.bin", "test2.bin"]))
        for entry in archive.index.entries.values where entry.kind == .file {
            #expect(try archive.contents(of: entry.id).count == Int(entry.size), "\(entry.name)")
        }

        // libarchive verifies the RAR5 checksums itself while extracting
        let poem = try #require(try archive.text(at: "cebula.txt"))
        #expect(poem.hasPrefix("Cebula"))
    }

    /// 7z cut into pieces the way 7-Zip does it ("Name.7z.001", ".002" …).
    private func makeSplit7z(chunk: Int = 40_000) throws -> [URL] {
        let whole = try make7z(in: dir, ["big.bin": big, "small.txt": Data("small".utf8)],
                               options: ["--options", "7zip:compression=store"])
        let data = try Data(contentsOf: whole)
        var parts: [URL] = []
        for (index, start) in stride(from: 0, to: data.count, by: chunk).enumerated() {
            let part = dir.appendingPathComponent("Photos.7z." + String(format: "%03d", index + 1))
            try data[start..<min(start + chunk, data.count)].write(to: part)
            parts.append(part)
        }
        #expect(parts.count >= 3)
        return parts
    }

    @Test func split7z() throws {
        let parts = try makeSplit7z()
        let archive = try Archive(url: parts[1])   // any part
        #expect(archive.format == .sevenZip)
        #expect(archive.parts == parts)
        #expect(try archive.data(at: "big.bin") == big)
        #expect(try archive.text(at: "small.txt") == "small")
        #expect(!archive.canSave)
        #expect(EditableArchive(archive: archive).isReadOnly)
        #expect(Archive.volumeName(for: parts[0]) == "Photos")
        #expect(ArchiveParts.firstPart(of: parts.last!) == parts[0])
    }

    @Test func missingPartIsReported() throws {
        let parts = try makeSplit7z()
        try FileManager.default.removeItem(at: parts[2])
        // The message is localized; the missing part's name appears in every language
        do {
            _ = try Archive(url: parts[0])
            Issue.record("Missing part was not detected")
        } catch ArchiveError.openFailed(let reason) {
            #expect(reason.contains("Photos.7z.003"))
        }
    }

    @Test func ordinaryNamesAreNotParts() throws {
        for name in ["a.rar", "a.zip", "a.tar.gz", "part1.zip", "Report 2024.pdf.zip"] {
            #expect(try ArchiveParts.parts(for: dir.appendingPathComponent(name)) == nil, "\(name)")
        }
        #expect(Archive.isSplitZip(dir.appendingPathComponent("a.z01")))
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Photos.part01.rar")) == "Photos")
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Sources.tar.gz.001")) == "Sources")
    }
}
