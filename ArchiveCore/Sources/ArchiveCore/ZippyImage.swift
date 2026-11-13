import Foundation

/// Format, mit dem die FSKit-Variante ein ZIP als rohes Disk-Image anhängt.
///
///     [ ZIP-Bytes | Nullen | 512-Byte-Trailer ]   Gesamtlänge: Vielfaches von 4096
///
/// macOS 15 kann FSKit-Volumes nur aus Block-Geräten bauen. Die App legt darum
/// eine APFS-Kopie (Clone) des ZIPs an, füllt sie auf und hängt den Trailer an.
/// Danach wird sie als Disk-Image angehängt. Die Erweiterung erkennt das Gerät am
/// Trailer und liest daraus die echte ZIP-Länge und den Volumenamen.
///
/// Trailer (Little Endian): Kennung "ZIPPYIMG" (8) · Version (4) · ZIP-Länge (8) ·
/// Passwort-ID (16, Nullen = keine) · Namenslänge (2) · Name UTF-8 · Nullen.
///
/// Die Passwort-ID verweist auf einen Eintrag im gemeinsamen Schlüsselbund von App
/// und Erweiterung. Das Passwort selbst steht nie im Image.
public enum ZippyImage {
    public static let blockSize = 512
    /// Gesamtlänge ist ein Vielfaches davon, damit der Trailer auch bei Geräten
    /// mit 4096-Byte-Blöcken genau am Ende liegt.
    static let alignment = 4096
    static let magic = Array("ZIPPYIMG".utf8)
    static let version: UInt32 = 2
    static let headerLength = 8 + 4 + 8 + 16 + 2
    static let maxNameLength = blockSize - headerLength

    public struct Info: Equatable, Sendable {
        public let zipLength: UInt64
        public let name: String
        /// Schlüssel für das Passwort im gemeinsamen Schlüsselbund, falls nötig.
        public let passwordID: UUID?
    }

    // MARK: Schreiben (App)

    /// Legt `image` aus `zip` an: APFS-Clone (kostet keinen Platz, sofern auf
    /// demselben Volume), Auffüllen, Trailer. Das Original bleibt unverändert.
    public static func create(from zip: URL, at image: URL, name: String, passwordID: UUID? = nil) throws {
        try? FileManager.default.removeItem(at: image)
        try FileManager.default.copyItem(at: zip, to: image)   // nutzt clonefile() auf APFS

        let handle = try FileHandle(forWritingTo: image)
        defer { try? handle.close() }
        let zipLength = try handle.seekToEnd()
        let used = Int((zipLength + UInt64(blockSize)) % UInt64(alignment))
        let padding = (alignment - used) % alignment
        try handle.write(contentsOf: Data(count: padding)
                         + trailer(zipLength: zipLength, name: name, passwordID: passwordID))
    }

    static func trailer(zipLength: UInt64, name: String, passwordID: UUID? = nil) -> Data {
        var block = Data(magic)
        withUnsafeBytes(of: version.littleEndian) { block.append(contentsOf: $0) }
        withUnsafeBytes(of: zipLength.littleEndian) { block.append(contentsOf: $0) }
        withUnsafeBytes(of: (passwordID ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))).uuid) {
            block.append(contentsOf: $0)
        }
        let nameBytes = truncatedUTF8(name, maxBytes: maxNameLength)
        withUnsafeBytes(of: UInt16(nameBytes.count).littleEndian) { block.append(contentsOf: $0) }
        block.append(contentsOf: nameBytes)
        block.append(Data(count: blockSize - block.count))
        return block
    }

    /// Kürzt an einer Zeichengrenze, damit kein halbes UTF-8-Zeichen entsteht.
    private static func truncatedUTF8(_ string: String, maxBytes: Int) -> [UInt8] {
        var result: [UInt8] = []
        for character in string {
            let bytes = Array(String(character).utf8)
            if result.count + bytes.count > maxBytes { break }
            result += bytes
        }
        return result
    }

    // MARK: Lesen (Erweiterung)

    /// Wertet den letzten Block eines Geräts aus. `nil`, wenn es kein Zippy-Image ist.
    public static func parse(lastBlock: Data, deviceLength: UInt64) -> Info? {
        let bytes = [UInt8](lastBlock.prefix(blockSize))
        guard bytes.count == blockSize, Array(bytes[0..<8]) == magic else { return nil }
        func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            bytes[offset..<offset + MemoryLayout<T>.size].reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }
        guard integer(8, UInt32.self) == version else { return nil }
        let zipLength = integer(12, UInt64.self)
        let idBytes = Array(bytes[20..<36])
        let passwordID = idBytes.allSatisfy { $0 == 0 } ? nil : UUID(uuid: (
            idBytes[0], idBytes[1], idBytes[2], idBytes[3], idBytes[4], idBytes[5], idBytes[6], idBytes[7],
            idBytes[8], idBytes[9], idBytes[10], idBytes[11], idBytes[12], idBytes[13], idBytes[14], idBytes[15]))
        let nameLength = Int(integer(36, UInt16.self))
        guard zipLength > 0, zipLength + UInt64(blockSize) <= deviceLength,
              nameLength <= maxNameLength else { return nil }
        let name = String(decoding: bytes[headerLength..<headerLength + nameLength], as: UTF8.self)
        return Info(zipLength: zipLength, name: name, passwordID: passwordID)
    }

    /// Öffnet ein Zippy-Image auf einem blockweise lesbaren Gerät.
    /// - Parameter readBlocks: liest ab blockausgerichtetem Offset in den Puffer
    public static func open(blockSize deviceBlockSize: Int, blockCount: UInt64, date: Date = Date(),
                            password: String? = nil,
                            readBlocks: @escaping @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int)
        throws -> (archive: Archive, info: Info) {
        guard let info = try readInfo(blockSize: deviceBlockSize, blockCount: blockCount, readBlocks: readBlocks) else {
            throw ArchiveError.openFailed("kein Zippy-Image")
        }
        let source = BlockSource(size: info.zipLength, blockSize: deviceBlockSize, readBlocks: readBlocks)
        return (try Archive(source: source, date: date, password: password), info)
    }

    /// Liest nur den Trailer, z. B. zum Erkennen (Probe) eines Geräts.
    public static func readInfo(blockSize deviceBlockSize: Int, blockCount: UInt64,
                                readBlocks: @escaping @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int)
        throws -> Info? {
        let deviceLength = UInt64(deviceBlockSize) * blockCount
        guard deviceLength >= UInt64(blockSize) else { return nil }
        let whole = BlockSource(size: deviceLength, blockSize: deviceBlockSize, readBlocks: readBlocks)
        var block = Data(count: blockSize)
        let count = try block.withUnsafeMutableBytes {
            try whole.read(into: $0, at: deviceLength - UInt64(blockSize))
        }
        guard count == blockSize else { return nil }
        return parse(lastBlock: block, deviceLength: deviceLength)
    }
}
