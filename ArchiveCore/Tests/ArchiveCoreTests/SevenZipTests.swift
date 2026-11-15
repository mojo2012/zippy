import Foundation
import Testing
@testable import ArchiveCore

/// 7z: read, edit, save again as 7z. Plain test archives are built by the system tar
/// (bsdtar writes 7z, LZMA1, solid); encrypted ones need `7zz` (brew install sevenzip).
@Suite struct SevenZipTests {
    let dir: URL
    let big = Data((0..<400_000).map { UInt8(($0 * 7) % 253) })

    init() throws {
        dir = try makeTempDir("7z")
    }

    @Test func reads7z() throws {
        let archive = try Archive(url: make7z(in: dir, ["a.txt": Data("one".utf8), "Folder/Grüße.txt": Data("two".utf8),
                                                        "Folder/big.bin": big, "empty.txt": Data()]))
        #expect(archive.format == .sevenZip)
        #expect(!archive.needsPassword)
        #expect(try archive.text(at: "a.txt") == "one")
        #expect(try archive.text(at: "Folder/Grüße.txt") == "two")
        #expect(try archive.text(at: "empty.txt") == "")
        let entry = try #require(archive.index.lookup(path: "Folder/big.bin"))
        #expect(entry.size == UInt64(big.count))
        #expect(try archive.read(entry.id, offset: 123_456, length: 100) == big[123_456..<123_556])
    }

    @Test func savesAs7z() throws {
        let original = try make7z(in: dir, ["a.txt": Data("old".utf8), "gone.txt": Data("x".utf8), "big.bin": big])
        let stamp = try EditableArchive.FileStamp(of: original)
        let editable = EditableArchive(archive: try Archive(url: original))
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEW".utf8), at: 0)
        try editable.removeFile(at: "gone.txt")
        try editable.createDirectory(at: "Grüße")
        let file = try editable.createFile(at: "Gru\u{308}ße/new.txt")
        try editable.write(file.id, data: Data("deep".utf8), at: 0)
        #expect(try editable.saveReplacing(original, ifUnchangedSince: stamp) == original)

        let saved = try Archive(url: original)
        #expect(saved.format == .sevenZip)
        #expect(try saved.text(at: "a.txt") == "NEW")
        #expect(saved.index.lookup(path: "gone.txt") == nil)
        #expect(try saved.text(at: "Grüße/new.txt") == "deep")
        #expect(try saved.data(at: "big.bin") == big)
        // The system tar reads the result too
        #expect(try run("/usr/bin/tar", ["-tf", original.path]).contains("big.bin"))
    }

    /// Encrypted 7z (data only, or names too), readable through the AES patch for libarchive.
    private func makeEncrypted(encryptedNames: Bool) throws -> URL {
        try makeEncrypted7z(in: dir, ["secret.txt": Data("secret".utf8), "Folder/big.bin": big],
                            password: "secret", encryptedNames: encryptedNames)
    }

    @Test(.enabled(if: has7zz), arguments: [false, true])
    func readsEncrypted(encryptedNames: Bool) throws {
        let archive = try Archive(url: makeEncrypted(encryptedNames: encryptedNames), password: "secret")
        #expect(archive.needsPassword)
        try archive.checkPassword()
        #expect(try archive.text(at: "secret.txt") == "secret")
        #expect(try archive.data(at: "Folder/big.bin") == big)
        // Saving would write unencrypted, so it stays read-only
        #expect(!archive.canSave)
        #expect(EditableArchive(archive: archive).isReadOnly)
    }

    @Test(.enabled(if: has7zz))
    func encryptedDataNeedsPassword() throws {
        let url = try makeEncrypted(encryptedNames: false)
        let listed = try Archive(url: url)   // names are readable
        #expect(listed.needsPassword)
        #expect(throws: ArchiveError.passwordRequired) { try listed.checkPassword() }
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: url, password: "wrong").checkPassword() }
    }

    @Test(.enabled(if: has7zz))
    func encryptedNamesNeedPasswordToOpen() throws {
        let url = try makeEncrypted(encryptedNames: true)
        #expect(throws: ArchiveError.passwordRequired) { try Archive(url: url) }
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: url, password: "wrong") }
    }

    @Test func copyKeepsExtension() {
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("Photos.7z"), suffix: "edited")
            .lastPathComponent == "Photos (edited).7z")
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("Sources.tar.xz"), suffix: "edited")
            .lastPathComponent == "Sources (edited).tar.xz")
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Sources.tar.xz")) == "Sources")
    }
}
