import Foundation
import Testing
@testable import ArchiveCore

/// Password-protected ZIPs: legacy ZipCrypto (macOS `zip -P`) and AES-256 (bsdtar).
@Suite struct PasswordTests {
    enum Method: String, CaseIterable { case zipCrypto, aes }

    let dir: URL
    let src: URL
    let secret = Data("top secret\n".utf8)

    init() throws {
        dir = try makeTempDir("password")
        src = try makeSourceDir(in: dir, files: ["secret.txt": secret, "empty.txt": Data()])
    }

    private func makeZip(_ method: Method, password: String) throws -> URL {
        let zip = dir.appendingPathComponent("\(method.rawValue).zip")
        switch method {
        case .zipCrypto:
            try run("/usr/bin/zip", ["-q", "-P", password, zip.path, "secret.txt", "empty.txt"], in: src)
        case .aes:
            try run("/usr/bin/bsdtar", ["--format", "zip", "--options", "zip:encryption=aes256",
                                        "--passphrase", password, "-cf", zip.path, "secret.txt", "empty.txt"], in: src)
        }
        return zip
    }

    /// With an umlaut: Process passes arguments decomposed (NFD), we give the password
    /// composed (NFC). It must still match.
    @Test(arguments: Method.allCases)
    func readsWithCorrectPassword(_ method: Method) throws {
        let zip = try makeZip(method, password: "Pa55wört")
        let archive = try Archive(url: zip, password: "Pa55wört")
        #expect(archive.needsPassword)
        try archive.checkPassword()
        #expect(try archive.data(at: "secret.txt") == secret)
    }

    @Test(arguments: Method.allCases)
    func listsWithoutPasswordButRefusesToRead(_ method: Method) throws {
        let zip = try makeZip(method, password: "abc")
        let archive = try Archive(url: zip)
        #expect(archive.needsPassword)
        let entry = try #require(archive.index.lookup(path: "secret.txt"))
        #expect(entry.isEncrypted)
        #expect(throws: ArchiveError.passwordRequired) { try archive.contents(of: entry.id) }
        #expect(throws: ArchiveError.passwordRequired) { try archive.checkPassword() }
    }

    @Test(arguments: Method.allCases)
    func detectsWrongPassword(_ method: Method) throws {
        let zip = try makeZip(method, password: "right")
        let archive = try Archive(url: zip, password: "wrong")
        #expect(throws: ArchiveError.wrongPassword) { try archive.checkPassword() }
    }

    @Test func passwordVariantsCoverCommonEncodings() {
        let variants = ArchiveReader.passwordVariants("ö")
        let bytes = variants.map { $0.dropLast().map { UInt8(bitPattern: $0) } }
        #expect(bytes.contains([0xC3, 0xB6]))         // UTF-8 NFC
        #expect(bytes.contains([0x6F, 0xCC, 0x88]))   // UTF-8 NFD
        #expect(bytes.contains([0xF6]))               // Windows-1252
        #expect(bytes.contains([0x94]))               // DOS 437
        #expect(ArchiveReader.passwordVariants("abc").count == 1)   // ASCII: a single variant
    }

    @Test func plainArchiveNeedsNoPassword() throws {
        let zip = dir.appendingPathComponent("plain.zip")
        try run("/usr/bin/zip", ["-q", zip.path, "secret.txt"], in: src)
        let archive = try Archive(url: zip)
        #expect(!archive.needsPassword)
        try archive.checkPassword()   // nothing to check
    }
}
