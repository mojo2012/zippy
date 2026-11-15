import Foundation
import Testing
@testable import ArchiveCore

/// RAR 4 and 5: read only. Test archives from libarchive (Fixtures), compared with
/// what the system tar extracts from them.
@Suite struct RarTests {
    let dir: URL

    init() throws {
        dir = try makeTempDir("rar")
    }

    /// Extracts with /usr/bin/tar and compares every file and link with the archive.
    @Test(arguments: ["rar", "rar_compress_normal", "rar5_multiple_files", "rar5_solid",
                      "rar5_unicode", "rar5_symlink", "rar5_stored"])
    func matchesSystemTar(_ name: String) throws {
        let url = try fixture(name)
        let archive = try Archive(url: url)
        #expect(archive.format == .rar)
        #expect(!archive.needsPassword)

        let out = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try run("/usr/bin/tar", ["-xf", url.path, "-C", out.path])

        let paths = try FileManager.default.subpathsOfDirectory(atPath: out.path)
        #expect(!paths.isEmpty)
        for path in paths {
            let file = out.appendingPathComponent(path)
            let entry = try #require(archive.index.lookup(path: path), "missing: \(path)")
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
        #expect(throws: POSIXError(.EROFS)) { try editable.createFile(at: "new.txt") }
    }

    /// libarchive cannot decrypt encrypted RAR data or file names.
    @Test(arguments: ["rar4_encrypted", "rar5_encrypted", "rar4_encrypted_filenames", "rar5_encrypted_filenames"])
    func rejectsEncrypted(_ name: String) throws {
        #expect(throws: ArchiveError.openFailed(Archive.encryptedUnsupported(.rar))) {
            try Archive(url: fixture(name), password: "test")
        }
    }

    @Test func volumeName() {
        #expect(Archive.volumeName(for: URL(fileURLWithPath: "/tmp/Photos.rar")) == "Photos")
    }
}
