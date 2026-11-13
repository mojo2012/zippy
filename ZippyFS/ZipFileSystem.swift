import FSKit
import os

let log = Logger(subsystem: "dev.zippy.ZippyFSKit.ZippyFS", category: "fs")

/// Prüft Block-Geräte auf eine ZIP-Signatur und liefert dafür ein Volume.
///
/// Sequoia-Prototyp: macOS 15 kann FSKit-Volumes nur aus Block-Geräten bauen.
/// Die App hängt das ZIP deshalb als rohes Disk-Image an (siehe README).
final class ZipFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    func probeResource(resource: FSResource,
                       replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            log.info("probe: keine Block-Ressource")
            return replyHandler(.notRecognized, nil)
        }
        log.info("probe: \(device.bsdName, privacy: .public), \(device.blockCount) Blöcke")
        guard Self.hasZipSignature(device) else {
            return replyHandler(.notRecognized, nil)
        }
        replyHandler(.usable(name: "Zippy", containerID: FSContainerIdentifier(uuid: UUID())), nil)
    }

    func loadResource(resource: FSResource,
                      options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let device = resource as? FSBlockDeviceResource else {
            return replyHandler(nil, POSIXError(.EINVAL))
        }
        log.info("load: \(device.bsdName, privacy: .public)")
        containerStatus = .ready
        let size = device.blockSize * device.blockCount
        replyHandler(ZipVolume(info: "FSKit hat das ZIP erkannt (\(size) Bytes Block-Gerät).\n"), nil)
    }

    func unloadResource(resource: FSResource,
                        options: FSTaskOptions,
                        replyHandler: @escaping ((any Error)?) -> Void) {
        log.info("unload")
        replyHandler(nil)
    }

    /// ZIP-Dateien beginnen mit "PK\u{3}\u{4}" (leere ZIPs mit "PK\u{5}\u{6}").
    private static func hasZipSignature(_ device: FSBlockDeviceResource) -> Bool {
        let length = Int(max(device.blockSize, 512))
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: 16)
        defer { buffer.deallocate() }
        guard let read = try? device.read(into: buffer, startingAt: 0, length: length), read >= 4 else {
            return false
        }
        let magic = Array(buffer.prefix(4))
        return magic == [0x50, 0x4B, 0x03, 0x04] || magic == [0x50, 0x4B, 0x05, 0x06]
    }
}
