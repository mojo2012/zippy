import Foundation

/// Format the FSKit variant uses to attach a ZIP as a raw disk image.
///
///     [ ZIP bytes | zeros | 512-byte trailer ]   total length: multiple of 4096
///
/// macOS 15 can only build FSKit volumes from block devices. So the app makes an APFS
/// clone of the ZIP, pads it and appends the trailer, then attaches it as a disk image.
/// The extension recognizes the device by the trailer and reads the real ZIP length and
/// the volume name from it.
///
/// Trailer (little endian): magic "ZIPPYIMG" (8) · version (4) · ZIP length (8) ·
/// password ID (16, zeros = none) · name length (2) · name in UTF-8 · zeros.
///
/// The password ID refers to an item in the keychain shared by app and extension.
/// The password itself is never stored in the image.
public enum ZippyImage {
    public static let blockSize = 512
    /// The total length is a multiple of this so the trailer sits exactly at the end
    /// even on devices with 4096-byte blocks.
    static let alignment = 4096
    static let magic = Array("ZIPPYIMG".utf8)
    static let version: UInt32 = 2
    static let headerLength = 8 + 4 + 8 + 16 + 2
    static let maxNameLength = blockSize - headerLength

    public struct Info: Equatable, Sendable {
        public let zipLength: UInt64
        public let name: String
        /// Key of the password in the shared keychain, if needed.
        public let passwordID: UUID?
    }

    // MARK: Writing (app)

    /// Creates `image` from `zip`: APFS clone (free if on the same volume), padding,
    /// trailer. The original is left unchanged.
    public static func create(from zip: URL, at image: URL, name: String, passwordID: UUID? = nil) throws {
        try? FileManager.default.removeItem(at: image)
        try FileManager.default.copyItem(at: zip, to: image)   // uses clonefile() on APFS

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
        if let passwordID {
            withUnsafeBytes(of: passwordID.uuid) { block.append(contentsOf: $0) }
        } else {
            block.append(Data(count: MemoryLayout<uuid_t>.size))
        }
        let nameBytes = truncatedUTF8(name, maxBytes: maxNameLength)
        withUnsafeBytes(of: UInt16(nameBytes.count).littleEndian) { block.append(contentsOf: $0) }
        block.append(contentsOf: nameBytes)
        block.append(Data(count: blockSize - block.count))
        return block
    }

    /// Truncates at a character boundary so no partial UTF-8 character remains.
    private static func truncatedUTF8(_ string: String, maxBytes: Int) -> [UInt8] {
        var result: [UInt8] = []
        for character in string {
            let bytes = Array(String(character).utf8)
            if result.count + bytes.count > maxBytes { break }
            result += bytes
        }
        return result
    }

    // MARK: Reading (extension)

    /// Parses the last block of a device. `nil` if it isn't a Zippy image.
    public static func parse(lastBlock: Data, deviceLength: UInt64) -> Info? {
        let bytes = [UInt8](lastBlock.prefix(blockSize))
        guard bytes.count == blockSize, Array(bytes[0..<8]) == magic else { return nil }
        func integer<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            bytes[offset..<offset + MemoryLayout<T>.size].reversed().reduce(T(0)) { $0 << 8 | T($1) }
        }
        guard integer(8, UInt32.self) == version else { return nil }
        let zipLength = integer(12, UInt64.self)
        let idBytes = bytes[20..<36]
        let passwordID = idBytes.allSatisfy { $0 == 0 } ? nil
            : UUID(uuid: idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        let nameLength = Int(integer(36, UInt16.self))
        guard zipLength > 0, zipLength + UInt64(blockSize) <= deviceLength,
              nameLength <= maxNameLength else { return nil }
        let name = String(decoding: bytes[headerLength..<headerLength + nameLength], as: UTF8.self)
        return Info(zipLength: zipLength, name: name, passwordID: passwordID)
    }

    /// Opens a Zippy image on a device that is read in blocks.
    /// - Parameter readBlocks: reads into the buffer from a block-aligned offset
    public static func open(blockSize deviceBlockSize: Int, blockCount: UInt64, date: Date = Date(),
                            password: String? = nil,
                            readBlocks: @escaping @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int)
        throws -> (archive: Archive, info: Info) {
        guard let info = try readInfo(blockSize: deviceBlockSize, blockCount: blockCount, readBlocks: readBlocks) else {
            throw ArchiveError.openFailed(String(localized: "not a Zippy image", bundle: .module))
        }
        let source = BlockSource(size: info.zipLength, blockSize: deviceBlockSize, readBlocks: readBlocks)
        return (try Archive(source: source, date: date, password: password), info)
    }

    /// Reads only the trailer, e.g. to probe a device.
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
