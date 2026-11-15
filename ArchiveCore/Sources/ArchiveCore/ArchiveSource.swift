import Foundation

/// Where the archive's bytes come from: a file (FUSE variants) or a block device
/// (FSKit extension). Reads use explicit offsets and may happen from several threads
/// at once.
public protocol ArchiveSource: Sendable {
    /// Length of the archive in bytes.
    var size: UInt64 { get }

    /// Reads at most `buffer.count` bytes from `offset`. 0 means end of data.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

/// An archive in a file.
public final class FileSource: ArchiveSource, @unchecked Sendable {
    public let size: UInt64
    private let descriptor: Int32

    public init(url: URL) throws {
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ArchiveError.openFailed(String(cString: strerror(errno)))
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            Darwin.close(descriptor)
            throw ArchiveError.openFailed(String(cString: strerror(errno)))
        }
        size = UInt64(info.st_size)
    }

    deinit { Darwin.close(descriptor) }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        let count = pread(descriptor, buffer.baseAddress, buffer.count, off_t(offset))
        guard count >= 0 else { throw ArchiveError.readFailed(String(cString: strerror(errno))) }
        return count
    }
}

/// An archive on a device that can only be read in whole blocks (e.g.
/// `FSBlockDeviceResource`). Translates arbitrary reads into block-aligned ones and
/// limits them to the logical length `size`.
public final class BlockSource: ArchiveSource, @unchecked Sendable {
    public let size: UInt64
    public let blockSize: Int
    private let readBlocks: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int

    /// - Parameters:
    ///   - size: logical length of the archive (may be smaller than the device)
    ///   - blockSize: block size of the device
    ///   - readBlocks: reads a block-aligned length from a block-aligned offset into the
    ///     buffer and returns the number of bytes read
    public init(size: UInt64, blockSize: Int,
                readBlocks: @escaping @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int) {
        self.size = size
        self.blockSize = blockSize
        self.readBlocks = readBlocks
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < size, buffer.count > 0 else { return 0 }
        let wanted = Int(min(UInt64(buffer.count), size - offset))
        let block = UInt64(blockSize)
        let alignedStart = offset / block * block
        let alignedEnd = (offset + UInt64(wanted) + block - 1) / block * block
        let alignedLength = Int(alignedEnd - alignedStart)

        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: alignedLength, alignment: 16)
        defer { scratch.deallocate() }
        let got = try readBlocks(scratch, alignedStart)

        let skip = Int(offset - alignedStart)
        let available = max(0, min(wanted, got - skip))
        if available > 0 {
            buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: scratch[skip..<skip + available]))
        }
        return available
    }
}

/// Several files as one: the parts of a split archive, read one after another.
///
/// This covers every kind Zippy knows: `.7z.001`, `.zip.001` … are plain byte slices.
/// Multi-part RAR (`.part1.rar`, `.rar` + `.r00`) has headers in each part, but libarchive
/// reads those as one continuous stream too (as with `archive_read_open_filenames`).
public final class MultiPartSource: ArchiveSource, @unchecked Sendable {
    public let size: UInt64
    private let parts: [(source: FileSource, start: UInt64)]

    public init(urls: [URL]) throws {
        var parts: [(FileSource, UInt64)] = []
        var offset: UInt64 = 0
        for url in urls {
            let source = try FileSource(url: url)
            parts.append((source, offset))
            offset += source.size
        }
        self.parts = parts
        size = offset
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
        guard offset < size, buffer.count > 0 else { return 0 }
        // Find the part containing the start, then keep reading across part boundaries
        var index = parts.lastIndex { $0.start <= offset } ?? 0
        var position = offset
        var filled = 0
        while filled < buffer.count, index < parts.count {
            let part = parts[index]
            let inPart = position - part.start
            guard inPart < part.source.size else { index += 1; continue }
            let wanted = min(buffer.count - filled, Int(part.source.size - inPart))
            let count = try part.source.read(into: UnsafeMutableRawBufferPointer(rebasing: buffer[filled..<filled + wanted]),
                                             at: inPart)
            if count == 0 { break }
            filled += count
            position += UInt64(count)
        }
        return filled
    }
}
