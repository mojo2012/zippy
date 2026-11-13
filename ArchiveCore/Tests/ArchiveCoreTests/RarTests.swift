import Foundation
import Testing
@testable import ArchiveCore

/// RAR 4 und 5: nur lesen. Testarchive aus libarchive (Fixtures), verglichen mit dem,
/// was das System-tar daraus entpackt.
@Suite struct RarTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-rar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
    }

    /// Entpackt mit /usr/bin/tar und vergleicht jede Datei und jeden Link mit dem Archiv.
    @Test(arguments: ["rar", "rar_compress_normal", "rar5_multiple_files", "rar5_solid",
                      "rar5_unicode", "rar5_symlink", "rar5_stored"])
    func matchesSystemTar(_ name: String) throws {
        let url = try fixture(name)
        let archive = try Archive(url: url)
        #expect(archive.format == .rar)
        #expect(!archive.needsPassword)

        let out = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xf", url.path, "-C", out.path]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)

        let paths = try #require(FileManager.default.subpathsOfDirectory(atPath: out.path) as [String]?)
        #expect(!paths.isEmpty)
        for path in paths {
            let file = out.appendingPathComponent(path)
            let entry = try #require(archive.index.lookup(path: path), "fehlt: \(path)")
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                #expect(entry.symlinkTarget == (try FileManager.default.destinationOfSymbolicLink(atPath: file.path)))
            } else if values.isDirectory == true {
                #expect(entry.isDirectory, "\(path)")
            } else {
                #expect(try archive.contents(of: entry.id) == Data(contentsOf: file), "\(path)")
            }
        }
    }

    @Test func isReadOnly() throws {
        let editable = EditableArchive(archive: try Archive(url: fixture("rar5_stored")))
        #expect(editable.isReadOnly)
        #expect(throws: POSIXError(.EROFS)) { try editable.createFile(at: "neu.txt") }
    }

    /// Verschlüsselte Daten oder Dateinamen kann libarchive bei RAR nicht entschlüsseln.
    @Test(arguments: ["rar4_encrypted", "rar5_encrypted", "rar4_encrypted_filenames", "rar5_encrypted_filenames"])
    func rejectsEncrypted(_ name: String) throws {
        #expect(throws: ArchiveError.openFailed(Archive.encryptedUnsupported(.rar))) {
            try Archive(url: fixture(name), password: "test")
        }
    }

    @Test func recognizesMultiPartNames() {
        for name in ["a.part1.rar", "a.part01.rar", "a.r00", "a.7z.001", "a.z01"] {
            #expect(Archive.isMultiPart(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
        for name in ["a.rar", "a.zip", "a.tar.gz", "part1.zip"] {
            #expect(!Archive.isMultiPart(URL(fileURLWithPath: "/tmp/\(name)")), "\(name)")
        }
    }

    @Test func volumeName() {
        #expect(Archive.volumeName(for: URL(fileURLWithPath: "/tmp/Fotos.rar")) == "Fotos")
    }
}
