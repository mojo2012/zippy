import Foundation
import Testing
@testable import ArchiveCore

/// Zippy image (FSKit variant): ZIP + padding + trailer, read as from a block device
/// that only delivers whole blocks.
@Suite struct ZippyImageTests {
    let dir: URL

    init() throws {
        dir = try makeTempDir("image")
    }

    /// Simulates a block device on top of the image file and checks that every read
    /// is block-aligned.
    private func device(_ image: URL, blockSize: Int) throws
        -> (blockCount: UInt64, read: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int) {
        let file = try FileSource(url: image)
        #expect(file.size % UInt64(blockSize) == 0, "Image must be block-aligned")
        let read: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int = { buffer, offset in
            precondition(offset % UInt64(blockSize) == 0, "Unaligned offset: \(offset)")
            precondition(buffer.count % blockSize == 0, "Unaligned length: \(buffer.count)")
            return try file.read(into: buffer, at: offset)
        }
        return (file.size / UInt64(blockSize), read)
    }

    @Test(arguments: [512, 4096])
    func roundTrip(blockSize: Int) throws {
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        let zip = try makeZip(in: dir, ["a.txt": Data("hello".utf8), "folder/big.bin": big])
        let image = dir.appendingPathComponent("test-\(blockSize).img")
        // Non-ASCII on purpose: the volume name is stored as UTF-8 in the trailer
        try ZippyImage.create(from: zip, at: image, name: "Grüße aus dem Archiv")

        let (count, read) = try device(image, blockSize: blockSize)
        let (archive, info) = try ZippyImage.open(blockSize: blockSize, blockCount: count, readBlocks: read)
        #expect(info.name == "Grüße aus dem Archiv")
        #expect(info.zipLength == (try FileSource(url: zip)).size)

        #expect(try archive.text(at: "a.txt") == "hello")
        let b = try #require(archive.index.lookup(path: "folder/big.bin"))
        #expect(try archive.contents(of: b.id) == big)
        #expect(try archive.read(b.id, offset: 123_457, length: 999) == big[123_457..<124_456])
    }

    @Test func carriesPasswordIDButNoPassword() throws {
        let id = UUID()
        let block = ZippyImage.trailer(zipLength: 99, name: "x", passwordID: id)
        #expect(ZippyImage.parse(lastBlock: block, deviceLength: 4096)?.passwordID == id)
        #expect(ZippyImage.parse(lastBlock: ZippyImage.trailer(zipLength: 99, name: "x"), deviceLength: 4096)?.passwordID == nil)
    }

    @Test func originalStaysUntouched() throws {
        let zip = try makeZip(in: dir, ["x.txt": Data("x".utf8)])
        let before = try Data(contentsOf: zip)
        try ZippyImage.create(from: zip, at: dir.appendingPathComponent("x.img"), name: "x")
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func rejectsPlainZipAndGarbage() throws {
        let zip = try makeZip(in: dir, ["x.txt": Data("x".utf8)])
        // A padded ZIP without trailer (the old prototype variant)
        var padded = try Data(contentsOf: zip)
        padded.append(Data(count: (512 - padded.count % 512) % 512))
        let plain = dir.appendingPathComponent("plain.img")
        try padded.write(to: plain)
        let (count, read) = try device(plain, blockSize: 512)
        #expect(try ZippyImage.readInfo(blockSize: 512, blockCount: count, readBlocks: read) == nil)

        let garbage = dir.appendingPathComponent("garbage.img")
        try Data(count: 4096).write(to: garbage)
        let (gCount, gRead) = try device(garbage, blockSize: 512)
        #expect(try ZippyImage.readInfo(blockSize: 512, blockCount: gCount, readBlocks: gRead) == nil)
    }

    @Test func longNamesAreCutAtCharacterBoundary() throws {
        let name = String(repeating: "ä", count: 400)   // 800 bytes of UTF-8
        let block = ZippyImage.trailer(zipLength: 10, name: name)
        #expect(block.count == ZippyImage.blockSize)
        let info = try #require(ZippyImage.parse(lastBlock: block, deviceLength: 4096))
        #expect(info.name.allSatisfy { $0 == "ä" })
        #expect(info.name.utf8.count <= ZippyImage.maxNameLength)
    }
}
