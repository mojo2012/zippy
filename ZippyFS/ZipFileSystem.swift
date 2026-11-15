import ArchiveCore
import FSKit
import os

let log = Logger(subsystem: "dev.zippy.ZippyFSKit.ZippyFS", category: "fs")

/// FSKit file system for Zippy images (see ``ZippyImage``).
///
/// macOS 15 can only build FSKit volumes from block devices, so the app attaches the
/// archive as a disk image. This extension recognizes the device by its Zippy trailer
/// and serves the contents through ArchiveCore, just like the FUSE variant.
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
            log.info("probe: \(device.bsdName, privacy: .public) is Zippy image \(info.name, privacy: .public)")
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
            let blockSize = Int(device.blockSize)
            var (archive, info) = try ZippyImage.open(blockSize: blockSize, blockCount: device.blockCount,
                                                      readBlocks: Self.reader(for: device))
            if archive.needsPassword, let password = Self.takePassword(for: info) {
                (archive, info) = try ZippyImage.open(blockSize: blockSize, blockCount: device.blockCount,
                                                      password: password, readBlocks: Self.reader(for: device))
            }
            log.info("load: \(info.name, privacy: .public), \(archive.index.entries.count) entries")
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

    /// Takes the password the app stored under the trailer's ID and deletes the item.
    /// Without a password the volume still mounts; encrypted files then fail with EACCES.
    private static func takePassword(for info: ZippyImage.Info) -> String? {
        guard let id = info.passwordID, let group = Keychain.sharedGroup else { return nil }
        let password = Keychain.load(service: Keychain.handoffService, account: id.uuidString, accessGroup: group)
        Keychain.delete(service: Keychain.handoffService, account: id.uuidString, accessGroup: group)
        if password == nil { log.error("Password for \(info.name, privacy: .public) not found in keychain") }
        return password
    }

    /// Block-wise reads from the device, for ``BlockSource``.
    private static func reader(for device: FSBlockDeviceResource)
        -> @Sendable (UnsafeMutableRawBufferPointer, UInt64) throws -> Int {
        nonisolated(unsafe) let device = device
        return { buffer, offset in
            try device.read(into: buffer, startingAt: off_t(offset), length: buffer.count)
        }
    }
}
