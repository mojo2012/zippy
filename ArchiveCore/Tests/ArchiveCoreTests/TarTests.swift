import Foundation
import Testing
@testable import ArchiveCore

/// TAR, auch mit gzip, bzip2, compress und xz: lesen, bearbeiten, im selben Format speichern.
@Suite struct TarTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-tar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Packt `files` mit /usr/bin/tar. `flags` z. B. "z" für gzip.
    private func makeTar(_ files: [String: Data], flags: String = "", name: String = "test.tar",
                         prepare: ((URL) throws -> Void)? = nil) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (path, data) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        try prepare?(src)
        let tar = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c\(flags)f", tar.path, "-C", src.path, "."]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return tar
    }

    private func text(_ archive: Archive, _ path: String) throws -> String? {
        guard let entry = archive.index.lookup(path: path) else { return nil }
        return String(decoding: try archive.contents(of: entry.id), as: UTF8.self)
    }

    @Test(arguments: [("", ArchiveFormat.tar(.none)), ("z", .tar(.gzip)), ("j", .tar(.bzip2)), ("Z", .tar(.compress)),
                      ("J", .tar(.xz))])
    func readsCompressedTars(flags: String, format: ArchiveFormat) throws {
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        let archive = try Archive(url: makeTar(["a.txt": Data("eins".utf8), "ordner/Grüße.txt": Data("zwei".utf8),
                                                "ordner/big.bin": big], flags: flags))
        #expect(archive.format == format)
        #expect(!archive.needsPassword)
        #expect(try text(archive, "a.txt") == "eins")
        #expect(try text(archive, "ordner/Grüße.txt") == "zwei")
        let entry = try #require(archive.index.lookup(path: "ordner/big.bin"))
        #expect(entry.size == UInt64(big.count))
        #expect(try archive.read(entry.id, offset: 1000, length: 10) == big[1000..<1010])
        #expect(archive.index.lookup(path: "ordner")?.isDirectory == true)
    }

    @Test func zipIsStillZip() throws {
        let src = dir.appendingPathComponent("z.txt")
        try Data("z".utf8).write(to: src)
        let zip = dir.appendingPathComponent("z.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", zip.path, src.path]
        try process.run()
        process.waitUntilExit()
        #expect(try Archive(url: zip).format == .zip)
    }

    @Test func gzipWithoutTarIsRejected() throws {
        let file = dir.appendingPathComponent("plain.txt")
        try Data("kein tar".utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [file.path]
        try process.run()
        process.waitUntilExit()
        #expect(throws: ArchiveError.self) { try Archive(url: dir.appendingPathComponent("plain.txt.gz")) }
    }

    @Test func hardlinksAndSymlinks() throws {
        let tar = try makeTar(["original.txt": Data("inhalt".utf8)]) { src in
            try FileManager.default.linkItem(at: src.appendingPathComponent("original.txt"),
                                             to: src.appendingPathComponent("hardlink.txt"))
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("symlink").path,
                                                       withDestinationPath: "original.txt")
        }
        let archive = try Archive(url: tar)
        #expect(try text(archive, "original.txt") == "inhalt")
        #expect(try text(archive, "hardlink.txt") == "inhalt")
        #expect(archive.index.lookup(path: "symlink")?.symlinkTarget == "original.txt")

        // Speichern behält beide Namen, der zweite bleibt ein Hardlink
        let editable = EditableArchive(archive: archive)
        try editable.createFile(at: "neu.txt")
        let output = dir.appendingPathComponent("out.tar")
        try editable.save(to: output)
        let saved = try Archive(url: output)
        #expect(try text(saved, "original.txt") == "inhalt")
        #expect(try text(saved, "hardlink.txt") == "inhalt")
        #expect(saved.index.lookup(path: "symlink")?.symlinkTarget == "original.txt")
    }

    @Test(arguments: [("z", ArchiveFormat.tar(.gzip)), ("j", .tar(.bzip2)), ("J", .tar(.xz)), ("", .tar(.none))])
    func savesInSameFormat(flags: String, format: ArchiveFormat) throws {
        let tar = try makeTar(["a.txt": Data("alt".utf8), "weg.txt": Data("x".utf8)], flags: flags)
        let stamp = try EditableArchive.FileStamp(of: tar)
        let editable = EditableArchive(archive: try Archive(url: tar))
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEU".utf8), at: 0)
        try editable.removeFile(at: "weg.txt")
        try editable.createDirectory(at: "Grüße")
        let file = try editable.createFile(at: "Gru\u{308}ße/\(String(repeating: "lang", count: 40)).txt")
        try editable.write(file.id, data: Data("tief".utf8), at: 0)
        #expect(try editable.saveReplacing(tar, ifUnchangedSince: stamp) == tar)

        let saved = try Archive(url: tar)
        #expect(saved.format == format)
        #expect(try text(saved, "a.txt") == "NEU")
        #expect(saved.index.lookup(path: "weg.txt") == nil)
        #expect(try text(saved, "Grüße/\(String(repeating: "lang", count: 40)).txt") == "tief")

        // Auch das System-tar liest das Ergebnis
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        list.arguments = ["-tf", tar.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        try list.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        #expect(list.terminationStatus == 0)
        #expect(output.contains("a.txt"))
    }

    @Test func copyKeepsDoubleExtension() throws {
        let url = dir.appendingPathComponent("Projekt.tar.gz")
        #expect(EditableArchive.unusedURL(like: url, suffix: "bearbeitet").lastPathComponent == "Projekt (bearbeitet).tar.gz")
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("a.zip"), suffix: "x").lastPathComponent == "a (x).zip")
    }
}
