import Foundation
import Testing
@testable import ArchiveCore

/// Setting, changing and removing passwords (the app's Finder services).
@Suite struct PasswordChangeTests {
    let dir: URL
    let big = Data((0..<200_000).map { UInt8(($0 * 31) % 255) })
    var files: [String: Data] { ["a.txt": Data("secret".utf8), "Folder/big.bin": big] }

    init() throws {
        dir = try makeTempDir("pwchange")
    }

    private func makeTestZip(password: String? = nil) throws -> URL {
        try makeZip(in: dir, files, flags: password.map { ["-P", $0] } ?? [])
    }

    /// Like the app: open, rewrite, replace the original.
    private func rewrite(_ url: URL, password: String?, _ encryption: EditableArchive.Encryption) throws {
        let stamp = try EditableArchive.FileStamp(of: url)
        let archive = try Archive(url: url, password: password)
        defer { archive.close() }
        let editable = EditableArchive(archive: archive)
        defer { editable.close() }
        #expect(try editable.saveReplacing(url, ifUnchangedSince: stamp, encryption: encryption) == url)
    }

    private func check(_ url: URL, password: String?) throws {
        let archive = try Archive(url: url, password: password)
        #expect(archive.needsPassword == (password != nil))
        #expect(try archive.data(at: "a.txt") == Data("secret".utf8))
        #expect(try archive.data(at: "Folder/big.bin") == big)
    }

    @Test func setPasswordOnPlainZip() throws {
        let zip = try makeTestZip()
        #expect(try Archive(url: zip).canSetPassword)
        try rewrite(zip, password: nil, .set("new"))
        try check(zip, password: "new")
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: zip, password: "wrong").checkPassword() }
    }

    /// ZIP only encrypts file contents: folders and empty files stay unencrypted.
    @Test func onlyFoldersStayUnencrypted() throws {
        let addFolder: (URL) throws -> Void = { src in
            try FileManager.default.createDirectory(at: src.appendingPathComponent("Folder"),
                                                    withIntermediateDirectories: true)
        }
        let foldersOnly = try makeZip(in: dir, [:], prepare: addFolder)
        try rewrite(foldersOnly, password: nil, .set("new"))
        #expect(try !Archive(url: foldersOnly).needsPassword)

        let withEmptyFile = try makeZip(in: dir, ["empty.txt": Data()], prepare: addFolder)
        try rewrite(withEmptyFile, password: nil, .set("new"))
        #expect(try !Archive(url: withEmptyFile).needsPassword)
    }

    @Test func changePassword() throws {
        let zip = try makeTestZip(password: "old")
        try rewrite(zip, password: "old", .set("new"))
        try check(zip, password: "new")
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: zip, password: "old").checkPassword() }
    }

    @Test func removePasswordFromZip() throws {
        let zip = try makeTestZip(password: "old")
        #expect(try Archive(url: zip).canRemovePassword)
        try rewrite(zip, password: "old", .remove)
        try check(zip, password: nil)
    }

    @Test(.enabled(if: has7zz), arguments: [false, true])
    func removePasswordFrom7z(encryptedNames: Bool) throws {
        let archive = try makeEncrypted7z(in: dir, files, password: "old", encryptedNames: encryptedNames)
        #expect(try Archive(url: archive, password: "old").canRemovePassword)
        #expect(try !Archive(url: archive, password: "old").canSetPassword)
        try rewrite(archive, password: "old", .remove)
        #expect(try Archive(url: archive).format == .sevenZip)
        try check(archive, password: nil)
    }

    @Test func noPasswordForTar() throws {
        let tar = try makeTar(in: dir, ["x.txt": Data("x".utf8)], flags: "z", name: "x.tar.gz")
        let archive = try Archive(url: tar)
        #expect(!archive.canSetPassword && !archive.canRemovePassword)
        #expect(throws: ArchiveError.self) {
            try EditableArchive(archive: archive).save(to: dir.appendingPathComponent("y.tar.gz"), encryption: .set("pw"))
        }
    }
}
