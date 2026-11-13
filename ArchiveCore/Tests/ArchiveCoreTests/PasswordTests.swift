import Foundation
import Testing
@testable import ArchiveCore

/// Passwortgeschützte ZIPs: altes ZipCrypto (macOS-`zip -P`) und AES-256 (bsdtar).
@Suite struct PasswordTests {
    enum Method: String, CaseIterable { case zipCrypto, aes }

    let dir: URL
    let secret = Data("streng geheim\n".utf8)

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try secret.write(to: dir.appendingPathComponent("src/geheim.txt"))
        try Data().write(to: dir.appendingPathComponent("src/leer.txt"))
    }

    private func makeZip(_ method: Method, password: String) throws -> URL {
        let zip = dir.appendingPathComponent("\(method.rawValue).zip")
        let process = Process()
        process.currentDirectoryURL = dir.appendingPathComponent("src")
        switch method {
        case .zipCrypto:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.arguments = ["-q", "-P", password, zip.path, "geheim.txt", "leer.txt"]
        case .aes:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["--format", "zip", "--options", "zip:encryption=aes256",
                                 "--passphrase", password, "-cf", zip.path, "geheim.txt", "leer.txt"]
        }
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }

    /// Mit Umlaut: Process übergibt Argumente zerlegt (NFD), wir geben das Passwort
    /// zusammengesetzt (NFC) an. Muss trotzdem passen.
    @Test(arguments: Method.allCases)
    func readsWithCorrectPassword(_ method: Method) throws {
        let zip = try makeZip(method, password: "Pa55wört")
        let archive = try Archive(url: zip, password: "Pa55wört")
        #expect(archive.needsPassword)
        try archive.checkPassword()
        let entry = try #require(archive.index.lookup(path: "geheim.txt"))
        #expect(try archive.contents(of: entry.id) == secret)
    }

    @Test(arguments: Method.allCases)
    func listsWithoutPasswordButRefusesToRead(_ method: Method) throws {
        let zip = try makeZip(method, password: "abc")
        let archive = try Archive(url: zip)
        #expect(archive.needsPassword)
        let entry = try #require(archive.index.lookup(path: "geheim.txt"))
        #expect(entry.isEncrypted)
        #expect(throws: ArchiveError.passwordRequired) { try archive.contents(of: entry.id) }
        #expect(throws: ArchiveError.passwordRequired) { try archive.checkPassword() }
    }

    @Test(arguments: Method.allCases)
    func detectsWrongPassword(_ method: Method) throws {
        let zip = try makeZip(method, password: "richtig")
        let archive = try Archive(url: zip, password: "falsch")
        #expect(throws: ArchiveError.wrongPassword) { try archive.checkPassword() }
    }

    @Test func passwordVariantsCoverCommonEncodings() {
        let variants = ArchiveReader.passwordVariants("ö")
        let bytes = variants.map { $0.dropLast().map { UInt8(bitPattern: $0) } }
        #expect(bytes.contains([0xC3, 0xB6]))         // UTF-8 NFC
        #expect(bytes.contains([0x6F, 0xCC, 0x88]))   // UTF-8 NFD
        #expect(bytes.contains([0xF6]))               // Windows-1252
        #expect(bytes.contains([0x94]))               // DOS 437
        #expect(ArchiveReader.passwordVariants("abc").count == 1)   // ASCII: nur eine Variante
    }

    @Test func plainArchiveNeedsNoPassword() throws {
        let zip = dir.appendingPathComponent("plain.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", zip.path, "geheim.txt"]
        process.currentDirectoryURL = dir.appendingPathComponent("src")
        try process.run()
        process.waitUntilExit()
        let archive = try Archive(url: zip)
        #expect(!archive.needsPassword)
        try archive.checkPassword()   // nichts zu prüfen
    }
}
