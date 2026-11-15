import DiskArbitration
import Foundation

/// Makes "Eject" in Finder work for macFUSE volumes.
///
/// macFUSE (FSKit, macOS 15) mounts via a helper block device whose mount
/// DiskArbitration doesn't know about, so Finder and `diskutil` fail with
/// "not mounted". This watcher registers with DiskArbitration for exactly that
/// device and, when an eject is requested, unmounts through macFUSE (`onEject`).
/// The eject then proceeds normally.
final class EjectWatcher: @unchecked Sendable {
    /// macFUSE's helper block device, e.g. "disk4".
    let bsdName: String
    private let session: DASession
    private let queue = DispatchQueue(label: "Zippy EjectWatcher")
    private let context: Unmanaged<Box>

    private final class Box {
        let mountPoint: String
        let onEject: @Sendable () -> Void
        init(_ mountPoint: String, _ onEject: @escaping @Sendable () -> Void) {
            self.mountPoint = mountPoint
            self.onEject = onEject
        }
    }

    /// `nil` if the mount point's device can't be determined.
    init?(mountPoint: String, onEject: @escaping @Sendable () -> Void) {
        guard let bsdName = Self.bsdName(of: mountPoint),
              let session = DASessionCreate(kCFAllocatorDefault) else { return nil }
        self.bsdName = bsdName
        self.session = session
        self.context = Unmanaged.passRetained(Box(mountPoint, onEject))
        DASessionSetDispatchQueue(session, queue)

        let match = [kDADiskDescriptionMediaBSDNameKey as String: bsdName] as CFDictionary
        let handler: DADiskUnmountApprovalCallback = { _, context in
            guard let context else { return nil }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            log.info("Eject requested: \(box.mountPoint, privacy: .public)")
            box.onEject()   // unmounting ends the FUSE loop
            return nil      // no objection
        }
        DARegisterDiskUnmountApprovalCallback(session, match, handler, context.toOpaque())
        DARegisterDiskEjectApprovalCallback(session, match, handler, context.toOpaque())
        log.info("Watching \(bsdName, privacy: .public) for eject")
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
        context.release()
    }

    /// Detaches the helper block device if it is still attached after unmounting.
    /// When unmounted via unmount(2) rather than Finder it would otherwise linger
    /// and block further macFUSE mounts.
    func detachDevice() {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", bsdName, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
        log.info("Detached device \(self.bsdName, privacy: .public) (\(detach.terminationStatus))")
    }

    /// "/dev/disk4" → "disk4"
    private static func bsdName(of mountPoint: String) -> String? {
        guard let device = FuseVolume.mountedFileSystems().first(where: { $0.mountPoint == mountPoint })?.device,
              device.hasPrefix("/dev/") else { return nil }
        return String(device.dropFirst("/dev/".count))
    }
}
