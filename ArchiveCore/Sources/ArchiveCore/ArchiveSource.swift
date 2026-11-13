import Foundation

/// Woher die Bytes des Archivs kommen: eine Datei (FUSE-Varianten) oder ein
/// Block-Gerät (FSKit-Erweiterung). Lesen geschieht positionsbezogen und darf
/// aus mehreren Threads gleichzeitig passieren.
public protocol ArchiveSource: Sendable {
    /// Länge des Archivs in Bytes.
    var size: UInt64 { get }

    /// Liest ab `offset` höchstens `buffer.count` Bytes. 0 heißt Ende.
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int
}

/// Archiv aus einer Datei.
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

/// Archiv auf einem Gerät, das nur in ganzen Blöcken gelesen werden kann
/// (z. B. `FSBlockDeviceResource`). Übersetzt beliebige Lesewünsche in
/// blockweise Zugriffe und begrenzt auf die logische Länge `size`.
public final class BlockSource: ArchiveSource, @unchecked Sendable {
    public let size: UInt64
    public let blockSize: Int
    private let readBlocks: @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int

    /// - Parameters:
    ///   - size: logische Länge des Archivs (kann kleiner sein als das Gerät)
    ///   - blockSize: Blockgröße des Geräts
    ///   - readBlocks: liest ab einem blockausgerichteten Offset eine
    ///     blockausgerichtete Länge in den Puffer, gibt die gelesene Anzahl zurück
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

/// Mehrere Dateien als eine: die Teile eines geteilten Archivs, hintereinander gelesen.
///
/// Reicht für alle Arten, die Zippy kennt: Bei `.7z.001`, `.zip.001` … sind die Teile
/// zerschnittene Bytes. Mehrteilige RAR (`.part1.rar`, `.rar` + `.r00`) haben zwar je
/// Teil eigene Köpfe, libarchive liest sie aber genauso als fortlaufenden Datenstrom
/// (wie bei `archive_read_open_filenames`).
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
        // Teil mit dem Anfang suchen, dann über Teilgrenzen weiterlesen
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
