import Foundation
import Testing
@testable import ArchiveCore

/// TAR, also with gzip, bzip2, compress and xz: read, edit, save in the same format.
@Suite struct TarTests {
    let dir: URL

    init() throws {
        dir = try makeTempDir("tar")
    }

    @Test(arguments: [("", ArchiveFormat.tar(.none)), ("z", .tar(.gzip)), ("j", .tar(.bzip2)), ("Z", .tar(.compress)),
                      ("J", .tar(.xz))])
    func readsCompressedTars(flags: String, format: ArchiveFormat) throws {
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        let archive = try Archive(url: makeTar(in: dir, ["a.txt": Data("one".utf8), "folder/Grüße.txt": Data("two".utf8),
                                                         "folder/big.bin": big], flags: flags))
        #expect(archive.format == format)
        #expect(!archive.needsPassword)
        #expect(try archive.text(at: "a.txt") == "one")
        #expect(try archive.text(at: "folder/Grüße.txt") == "two")
        let entry = try #require(archive.index.lookup(path: "folder/big.bin"))
        #expect(entry.size == UInt64(big.count))
        #expect(try archive.read(entry.id, offset: 1000, length: 10) == big[1000..<1010])
        #expect(archive.index.lookup(path: "folder")?.isDirectory == true)
    }

    @Test func zipIsStillZip() throws {
        #expect(try Archive(url: makeZip(in: dir, ["z.txt": Data("z".utf8)])).format == .zip)
    }

    @Test func gzipWithoutTarIsRejected() throws {
        let file = dir.appendingPathComponent("plain.txt")
        try Data("not a tar".utf8).write(to: file)
        try run("/usr/bin/gzip", [file.path])
        #expect(throws: ArchiveError.self) { try Archive(url: dir.appendingPathComponent("plain.txt.gz")) }
    }

    @Test func hardlinksAndSymlinks() throws {
        let tar = try makeTar(in: dir, ["original.txt": Data("content".utf8)]) { src in
            try FileManager.default.linkItem(at: src.appendingPathComponent("original.txt"),
                                             to: src.appendingPathComponent("hardlink.txt"))
            try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("symlink").path,
                                                       withDestinationPath: "original.txt")
        }
        let archive = try Archive(url: tar)
        #expect(try archive.text(at: "original.txt") == "content")
        #expect(try archive.text(at: "hardlink.txt") == "content")
        #expect(archive.index.lookup(path: "symlink")?.symlinkTarget == "original.txt")

        // Saving keeps both names; the second stays a hard link
        let editable = EditableArchive(archive: archive)
        try editable.createFile(at: "new.txt")
        let output = dir.appendingPathComponent("out.tar")
        try editable.save(to: output)
        let saved = try Archive(url: output)
        #expect(try saved.text(at: "original.txt") == "content")
        #expect(try saved.text(at: "hardlink.txt") == "content")
        #expect(saved.index.lookup(path: "symlink")?.symlinkTarget == "original.txt")
    }

    @Test(arguments: [("z", ArchiveFormat.tar(.gzip)), ("j", .tar(.bzip2)), ("J", .tar(.xz)), ("", .tar(.none))])
    func savesInSameFormat(flags: String, format: ArchiveFormat) throws {
        let tar = try makeTar(in: dir, ["a.txt": Data("old".utf8), "gone.txt": Data("x".utf8)], flags: flags)
        let stamp = try EditableArchive.FileStamp(of: tar)
        let editable = EditableArchive(archive: try Archive(url: tar))
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEW".utf8), at: 0)
        try editable.removeFile(at: "gone.txt")
        try editable.createDirectory(at: "Grüße")
        let longName = String(repeating: "long", count: 40) + ".txt"
        let file = try editable.createFile(at: "Gru\u{308}ße/\(longName)")
        try editable.write(file.id, data: Data("deep".utf8), at: 0)
        #expect(try editable.saveReplacing(tar, ifUnchangedSince: stamp) == tar)

        let saved = try Archive(url: tar)
        #expect(saved.format == format)
        #expect(try saved.text(at: "a.txt") == "NEW")
        #expect(saved.index.lookup(path: "gone.txt") == nil)
        #expect(try saved.text(at: "Grüße/\(longName)") == "deep")
        // The system tar reads the result too
        #expect(try run("/usr/bin/tar", ["-tf", tar.path]).contains("a.txt"))
    }

    @Test func copyKeepsDoubleExtension() throws {
        let url = dir.appendingPathComponent("Project.tar.gz")
        #expect(EditableArchive.unusedURL(like: url, suffix: "edited").lastPathComponent == "Project (edited).tar.gz")
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("a.zip"), suffix: "x").lastPathComponent == "a (x).zip")
    }
}
