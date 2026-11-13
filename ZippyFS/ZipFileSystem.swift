import ArchiveCore
import FSKit
import os

let log = Logger(subsystem: "dev.zippy.ZippyFSKit.ZippyFS", category: "fs")

/// FSKit-Dateisystem für Zippy-Images (siehe ``ZippyImage``).
///
/// macOS 15 kann FSKit-Volumes nur aus Block-Geräten bauen. Die App hängt das ZIP
/// deshalb als Disk-Image an; diese Erweiterung erkennt das Gerät am Zippy-Trailer
/// und stellt den Inhalt über ArchiveCore bereit, wie die FUSE-Varianten.
final class ZipFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    private var volume: ZipVolume?

    func probeResource(resource: FSResource,
                       replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            return replyHandler(.notRecognized, nil)
        }
        do {
            guard let info = try ZippyImage.readInfo(blockSize: Int(device.blockSize), blockCount: device.blockCount,
                                                     readBlocks: Self.reader(for: device)) else {
                return replyHandler(.notRecognized, nil)
            }
            log.info("probe: \(device.bsdName, privacy: .public) ist Zippy-Image \(info.name, privacy: .public)")
            replyHandler(.usable(name: info.name, containerID: FSContainerIdentifier(uuid: UUID())), nil)
        } catch {
            log.error("probe: \(error.localizedDescription, privacy: .public)")
            replyHandler(.notRecognized, nil)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        do {
            let (archive, info) = try ZippyImage.open(blockSize: Int(device.blockSize), blockCount: device.blockCount,
                                                      readBlocks: Self.reader(for: device))
            log.info("load: \(info.name, privacy: .public), \(archive.index.entries.count) Einträge")
            let volume = ZipVolume(archive: archive, name: info.name)
            self.volume = volume
            containerStatus = .ready
            replyHandler(volume, nil)
        } catch {
            log.error("load: \(error.localizedDescription, privacy: .public)")
            replyHandler(nil, POSIXError(.EIO))
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        volume?.archive.close()
        volume = nil
        replyHandler(nil)
    }

    /// Blockweises Lesen vom Gerät für ``BlockSource``.
    private static func reader(for device: FSBlockDeviceResource)
        -> @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int {
        nonisolated(unsafe) let device = device
        return { buffer, offset in
            try device.read(into: buffer, startingAt: off_t(offset), length: buffer.count)
        }
    }
}
