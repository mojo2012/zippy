import Foundation
import Testing
@testable import ArchiveCore

/// File names without the UTF-8 flag: Zippy guesses the code page the ZIP was packed with.
@Suite struct NameEncodingTests {
    let dir: URL

    init() throws {
        dir = try makeTempDir("names")
    }

    /// Minimal (stored) ZIP with exactly these name bytes and no UTF-8 flag,
    /// as a Windows packer writes it in its code page.
    private func makeZip(_ entries: [(name: [UInt8], content: String)]) throws -> URL {
        var local = Data(), central = Data()
        func le16(_ v: Int, _ d: inout Data) { d += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: UInt32, _ d: inout Data) { for i in 0..<4 { d.append(UInt8(v >> (8 * UInt32(i)) & 0xFF)) } }
        for entry in entries {
            let data = Data(entry.content.utf8)
            let crc = crc32(data)
            let offset = UInt32(local.count)
            le32(0x0403_4B50, &local); le16(20, &local); le16(0, &local); le16(0, &local)   // header, flags 0, stored
            le16(0, &local); le16(0x21, &local)                                               // time, date
            le32(crc, &local); le32(UInt32(data.count), &local); le32(UInt32(data.count), &local)
            le16(entry.name.count, &local); le16(0, &local)
            local += entry.name; local += data

            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le16(0x21, &central)
            le32(crc, &central); le32(UInt32(data.count), &central); le32(UInt32(data.count), &central)
            le16(entry.name.count, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le16(0, &central); le32(0, &central); le32(offset, &central)
            central += entry.name
        }
        var end = Data()
        le32(0x0605_4B50, &end); le16(0, &end); le16(0, &end)
        le16(entries.count, &end); le16(entries.count, &end)
        le32(UInt32(central.count), &end); le32(UInt32(local.count), &end); le16(0, &end)
        let url = dir.appendingPathComponent("test-\(uniqueName()).zip")
        try (local + central + end).write(to: url)
        return url
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    private func names(_ url: URL) throws -> Set<String> {
        let archive = try Archive(url: url)
        return Set(archive.index.entries.values.filter { $0.kind == .file }.map(\.name))
    }

    /// As in a Chinese vendor's BatteryView ZIP: GBK, alongside ASCII names.
    @Test func chineseGBK() throws {
        let zip = try makeZip([(Array("readme.txt".utf8), "a"),
                               (Array("Tool/".utf8) + [0xC7, 0xD0, 0xBB, 0xBB, 0xB5, 0xBD, 0xBF, 0xD8, 0xD6, 0xC6, 0xCC, 0xA8], "b")])
        #expect(try names(zip) == ["readme.txt", "切换到控制台"])
        let archive = try Archive(url: zip)
        let entry = try #require(archive.index.lookup(path: "Tool/切换到控制台"))
        #expect(try archive.contents(of: entry.id) == Data("b".utf8))
    }

    @Test func germanDOS() throws {
        // Code page 437/850: ü = 0x81, ß = 0xE1, Ö = 0x99, ä = 0x84
        let zip = try makeZip([(Array("Gr".utf8) + [0x81, 0xE1] + Array("e.txt".utf8), "a"),
                               ([0x99] + Array("l und K".utf8) + [0x84] + Array("se.doc".utf8), "b")])
        #expect(try names(zip) == ["Grüße.txt", "Öl und Käse.doc"])
    }

    @Test func windowsANSI() throws {
        // Code page 1252: ü = 0xFC, ß = 0xDF
        let zip = try makeZip([(Array("Gr".utf8) + [0xFC, 0xDF] + Array("e.txt".utf8), "a")])
        #expect(try names(zip) == ["Grüße.txt"])
    }

    @Test func japaneseShiftJIS() throws {
        let zip = try makeZip([([0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA] + Array(".txt".utf8), "a"),
                               ([0x82, 0xA0, 0x82, 0xA2] + Array(".txt".utf8), "b")])   // あい
        #expect(try names(zip) == ["日本語.txt", "あい.txt"])
    }

    @Test func russianDOS() throws {
        let zip = try makeZip([([0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2] + Array(".txt".utf8), "a")])   // Привет
        #expect(try names(zip) == ["Привет.txt"])
    }

    /// Byte 0xFF: a no-break space in DOS, "ÿ" in Windows-1252 (a real-world case).
    @Test func dosNoBreakSpace() throws {
        let zip = try makeZip([(Array("US2000B_".utf8) + [0xFF] + Array("UPdate".utf8) + [0xFF] + Array("_Software/a.txt".utf8), "a")])
        let archive = try Archive(url: zip)
        let folder = try #require(archive.index.children(of: ArchiveIndex.rootID).first)
        #expect(folder.name == "US2000B_\u{A0}UPdate\u{A0}_Software")
    }

    @Test func utf8WithoutFlagStaysUTF8() throws {
        let zip = try makeZip([(Array("Grüße.txt".utf8), "a")])
        #expect(try names(zip) == ["Grüße.txt"])
    }
}
