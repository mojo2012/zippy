import Foundation
import Testing
@testable import ArchiveCore

/// 7z: lesen, bearbeiten, wieder als 7z speichern. Testarchive baut das System-tar
/// (bsdtar kann 7z schreiben, LZMA1, solide).
@Suite struct SevenZipTests {
    let dir: URL
    let big = Data((0..<400_000).map { UInt8(($0 * 7) % 253) })

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-7z-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func make7z(_ files: [String: Data]) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (path, data) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let archive = dir.appendingPathComponent("test-\(UUID().uuidString.prefix(6)).7z")
        try run("/usr/bin/tar", ["--format", "7zip", "-cf", archive.path, "-C", src.path, "."])
        return archive
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return output
    }

    private func text(_ archive: Archive, _ path: String) throws -> String? {
        guard let entry = archive.index.lookup(path: path) else { return nil }
        return String(decoding: try archive.contents(of: entry.id), as: UTF8.self)
    }

    @Test func reads7z() throws {
        let archive = try Archive(url: make7z(["a.txt": Data("eins".utf8), "Ordner/Grüße.txt": Data("zwei".utf8),
                                               "Ordner/big.bin": big, "leer.txt": Data()]))
        #expect(archive.format == .sevenZip)
        #expect(!archive.needsPassword)
        #expect(try text(archive, "a.txt") == "eins")
        #expect(try text(archive, "Ordner/Grüße.txt") == "zwei")
        #expect(try text(archive, "leer.txt") == "")
        let entry = try #require(archive.index.lookup(path: "Ordner/big.bin"))
        #expect(entry.size == UInt64(big.count))
        #expect(try archive.read(entry.id, offset: 123_456, length: 100) == big[123_456..<123_556])
    }

    @Test func savesAs7z() throws {
        let original = try make7z(["a.txt": Data("alt".utf8), "weg.txt": Data("x".utf8), "big.bin": big])
        let stamp = try EditableArchive.FileStamp(of: original)
        let editable = EditableArchive(archive: try Archive(url: original))
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEU".utf8), at: 0)
        try editable.removeFile(at: "weg.txt")
        try editable.createDirectory(at: "Grüße")
        let file = try editable.createFile(at: "Gru\u{308}ße/neu.txt")
        try editable.write(file.id, data: Data("tief".utf8), at: 0)
        #expect(try editable.saveReplacing(original, ifUnchangedSince: stamp) == original)

        let saved = try Archive(url: original)
        #expect(saved.format == .sevenZip)
        #expect(try text(saved, "a.txt") == "NEU")
        #expect(saved.index.lookup(path: "weg.txt") == nil)
        #expect(try text(saved, "Grüße/neu.txt") == "tief")
        let entry = try #require(saved.index.lookup(path: "big.bin"))
        #expect(try saved.contents(of: entry.id) == big)
        // Auch das System-tar liest das Ergebnis
        #expect(try run("/usr/bin/tar", ["-tf", original.path]).contains("big.bin"))
    }

    /// Verschlüsseltes 7z (Daten bzw. auch Dateinamen) über den AES-Patch für libarchive.
    /// Braucht `7zz` (brew install sevenzip) zum Erzeugen.
    private func makeEncrypted7z(encryptedNames: Bool) throws -> URL {
        let src = dir.appendingPathComponent("enc-src-\(encryptedNames)", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Ordner"), withIntermediateDirectories: true)
        try Data("geheim".utf8).write(to: src.appendingPathComponent("geheim.txt"))
        try big.write(to: src.appendingPathComponent("Ordner/big.bin"))
        let archive = dir.appendingPathComponent("enc-\(encryptedNames).7z")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/7zz")
        process.arguments = ["a", "-bso0", "-pgeheim", "-mhe=\(encryptedNames ? "on" : "off")", archive.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return archive
    }

    static let has7zz = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7zz")

    @Test(.enabled(if: has7zz), arguments: [false, true])
    func readsEncrypted(encryptedNames: Bool) throws {
        let url = try makeEncrypted7z(encryptedNames: encryptedNames)
        let archive = try Archive(url: url, password: "geheim")
        #expect(archive.needsPassword)
        try archive.checkPassword()
        #expect(try text(archive, "geheim.txt") == "geheim")
        let entry = try #require(archive.index.lookup(path: "Ordner/big.bin"))
        #expect(try archive.contents(of: entry.id) == big)
        // Speichern würde unverschlüsselt schreiben: darum nur lesbar
        #expect(!archive.canSave)
        #expect(EditableArchive(archive: archive).isReadOnly)
    }

    @Test(.enabled(if: has7zz))
    func encryptedDataNeedsPassword() throws {
        let url = try makeEncrypted7z(encryptedNames: false)
        let listed = try Archive(url: url)   // Namen sind lesbar
        #expect(listed.needsPassword)
        #expect(throws: ArchiveError.passwordRequired) { try listed.checkPassword() }
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: url, password: "falsch").checkPassword() }
    }

    @Test(.enabled(if: has7zz))
    func encryptedNamesNeedPasswordToOpen() throws {
        let url = try makeEncrypted7z(encryptedNames: true)
        #expect(throws: ArchiveError.passwordRequired) { try Archive(url: url) }
        #expect(throws: ArchiveError.wrongPassword) { try Archive(url: url, password: "falsch") }
    }

    @Test func copyKeepsExtension() {
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("Fotos.7z"), suffix: "bearbeitet")
            .lastPathComponent == "Fotos (bearbeitet).7z")
        #expect(EditableArchive.unusedURL(like: dir.appendingPathComponent("Quellen.tar.xz"), suffix: "bearbeitet")
            .lastPathComponent == "Quellen (bearbeitet).tar.xz")
        #expect(Archive.volumeName(for: dir.appendingPathComponent("Quellen.tar.xz")) == "Quellen")
    }
}
