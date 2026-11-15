import Foundation
import Testing
@testable import ArchiveCore

/// Passwort setzen, ändern und entfernen (Finder-Dienste der App).
@Suite struct PasswordChangeTests {
    let dir: URL
    let big = Data((0..<200_000).map { UInt8(($0 * 31) % 255) })

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-pwchange-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func makeZip(password: String? = nil) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
        try Data("geheim".utf8).write(to: src.appendingPathComponent("a.txt"))
        try big.write(to: src.appendingPathComponent("Ordner/big.bin"))
        let zip = dir.appendingPathComponent("test-\(UUID().uuidString.prefix(6)).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r"] + (password.map { ["-P", $0] } ?? []) + [zip.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        return zip
    }

    /// Wie die App: öffnen, umschreiben, Original ersetzen.
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
        let a = try #require(archive.index.lookup(path: "a.txt"))
        #expect(try archive.contents(of: a.id) == Data("geheim".utf8))
        let b = try #require(archive.index.lookup(path: "Ordner/big.bin"))
        #expect(try archive.contents(of: b.id) == big)
    }

    @Test func setPasswordOnPlainZip() throws {
        let zip = try makeZip()
        #expect(try Archive(url: zip).canSetPassword)
        try rewrite(zip, password: nil, .set("neu"))
        try check(zip, password: "neu")
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: zip, password: "falsch").checkPassword() }
    }

    /// ZIP verschlüsselt nur Dateiinhalte: Ordner und leere Dateien bleiben offen.
    @Test func onlyFoldersStayUnencrypted() throws {
        let src = dir.appendingPathComponent("leer", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("leer.zip")
        func pack() throws {
            try? FileManager.default.removeItem(at: zip)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-r", zip.path, "."]
            process.currentDirectoryURL = src
            try process.run()
            process.waitUntilExit()
        }
        try pack()
        try rewrite(zip, password: nil, .set("neu"))
        #expect(try !Archive(url: zip).needsPassword)

        try Data().write(to: src.appendingPathComponent("leer.txt"))
        try pack()
        try rewrite(zip, password: nil, .set("neu"))
        #expect(try !Archive(url: zip).needsPassword)
    }

    @Test func changePassword() throws {
        let zip = try makeZip(password: "alt")
        try rewrite(zip, password: "alt", .set("neu"))
        try check(zip, password: "neu")
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: zip, password: "alt").checkPassword() }
    }

    @Test func removePasswordFromZip() throws {
        let zip = try makeZip(password: "alt")
        #expect(try Archive(url: zip).canRemovePassword)
        try rewrite(zip, password: "alt", .remove)
        try check(zip, password: nil)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7zz")), arguments: [false, true])
    func removePasswordFrom7z(encryptedNames: Bool) throws {
        let src = dir.appendingPathComponent("src7z-\(encryptedNames)", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
        try Data("geheim".utf8).write(to: src.appendingPathComponent("a.txt"))
        try big.write(to: src.appendingPathComponent("Ordner/big.bin"))
        let archive = dir.appendingPathComponent("enc-\(encryptedNames).7z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
        process.arguments = ["a", "-bso0", "-palt", "-mhe=\(encryptedNames ? "on" : "off")", archive.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()

        #expect(try Archive(url: archive, password: "alt").canRemovePassword)
        #expect(try !Archive(url: archive, password: "alt").canSetPassword)
        try rewrite(archive, password: "alt", .remove)
        let saved = try Archive(url: archive)
        #expect(saved.format == .sevenZip)
        try check(archive, password: nil)
    }

    @Test func noPasswordForTar() throws {
        let src = dir.appendingPathComponent("tarsrc", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: src.appendingPathComponent("x.txt"))
        let tar = dir.appendingPathComponent("x.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-czf", tar.path, "-C", src.path, "."]
        try process.run()
        process.waitUntilExit()
        let archive = try Archive(url: tar)
        #expect(!archive.canSetPassword && !archive.canRemovePassword)
        #expect(throws: ArchiveError.self) {
            try EditableArchive(archive: archive).save(to: dir.appendingPathComponent("y.tar.gz"), encryption: .set("pw"))
        }
    }
}
