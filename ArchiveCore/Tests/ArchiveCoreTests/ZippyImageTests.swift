import Foundation
import Testing
@testable import ArchiveCore

/// Zippy-Image (FSKit-Variante): ZIP + Auffüllen + Trailer, gelesen wie von
/// einem Block-Gerät, das nur ganze Blöcke liefert.
@Suite struct ZippyImageTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func makeZip(files: [String: Data]) throws -> URL {
        let src = dir.appendingPathComponent("src", isDirectory: true)
        for (path, data) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let zip = dir.appendingPathComponent("test.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zip.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        return zip
    }

    /// Simuliert ein Block-Gerät über der Image-Datei und prüft, dass nur
    /// blockausgerichtet gelesen wird.
    private func device(_ image: URL, blockSize: Int) throws
        -> (blockCount: UInt64, read: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int) {
        let file = try FileSource(url: image)
        #expect(file.size % UInt64(blockSize) == 0, "Image muss blockausgerichtet sein")
        let read: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int = { buffer, offset in
            precondition(offset % UInt64(blockSize) == 0, "Offset nicht ausgerichtet: \(offset)")
            precondition(buffer.count % blockSize == 0, "Länge nicht ausgerichtet: \(buffer.count)")
            return try file.read(into: buffer, at: offset)
        }
        return (file.size / UInt64(blockSize), read)
    }

    @Test(arguments: [512, 4096])
    func roundTrip(blockSize: Int) throws {
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        let zip = try makeZip(files: ["a.txt": Data("hallo".utf8), "ordner/big.bin": big])
        let image = dir.appendingPathComponent("test-\(blockSize).img")
        try ZippyImage.create(from: zip, at: image, name: "Grüße aus dem Archiv")

        let (count, read) = try device(image, blockSize: blockSize)
        let (archive, info) = try ZippyImage.open(blockSize: blockSize, blockCount: count, readBlocks: read)
        #expect(info.name == "Grüße aus dem Archiv")
        #expect(info.zipLength == (try FileSource(url: zip)).size)

        let a = try #require(archive.index.lookup(path: "a.txt"))
        #expect(try archive.contents(of: a.id) == Data("hallo".utf8))
        let b = try #require(archive.index.lookup(path: "ordner/big.bin"))
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
        let zip = try makeZip(files: ["x.txt": Data("x".utf8)])
        let before = try Data(contentsOf: zip)
        try ZippyImage.create(from: zip, at: dir.appendingPathComponent("x.img"), name: "x")
        #expect(try Data(contentsOf: zip) == before)
    }

    @Test func rejectsPlainZipAndGarbage() throws {
        let zip = try makeZip(files: ["x.txt": Data("x".utf8)])
        // Nur aufgefülltes ZIP ohne Trailer (alte Prototyp-Variante)
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
        let name = String(repeating: "ä", count: 400)   // 800 Bytes UTF-8
        let block = ZippyImage.trailer(zipLength: 10, name: name)
        #expect(block.count == ZippyImage.blockSize)
        let info = try #require(ZippyImage.parse(lastBlock: block, deviceLength: 4096))
        #expect(info.name.allSatisfy { $0 == "ä" })
        #expect(info.name.utf8.count <= ZippyImage.maxNameLength)
    }
}
