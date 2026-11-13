import DiskArbitration
import Foundation

/// Macht „Auswerfen“ im Finder für macFUSE-Volumes möglich.
///
/// macFUSE (FSKit, macOS 15) mountet über ein Hilfs-Block-Gerät, ohne dass
/// DiskArbitration den Mount kennt. Finder und `diskutil` scheitern dann mit
/// „not mounted“. Dieser Wächter meldet sich bei DiskArbitration für genau dieses
/// Gerät und lässt bei einer Auswurf-Anfrage über macFUSE aushängen (`onEject`).
/// Danach läuft der Auswurf normal weiter.
final class EjectWatcher: @unchecked Sendable {
    /// Das Hilfs-Block-Gerät von macFUSE, z. B. "disk4".
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

    /// `nil`, wenn das Gerät des Mountpunkts nicht ermittelt werden kann.
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
            log.info("Auswurf angefragt: \(box.mountPoint, privacy: .public)")
            box.onEject()   // aushängen, beendet die FUSE-Schleife
            return nil      // keine Einwände
        }
        DARegisterDiskUnmountApprovalCallback(session, match, handler, context.toOpaque())
        DARegisterDiskEjectApprovalCallback(session, match, handler, context.toOpaque())
        log.info("Auswurf-Wächter für \(bsdName, privacy: .public)")
    }

    deinit {
        DASessionSetDispatchQueue(session, nil)
        context.release()
    }

    /// Löst das Hilfs-Block-Gerät, falls es nach dem Aushängen noch angehängt ist.
    /// Wird per unmount(2) statt über den Finder ausgehängt, bleibt es sonst liegen
    /// und blockiert weitere macFUSE-Mounts.
    func detachDevice() {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", bsdName, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
        log.info("Gerät gelöst: \(self.bsdName, privacy: .public) (\(detach.terminationStatus))")
    }

    /// "/dev/disk4" → "disk4"
    private static func bsdName(of mountPoint: String) -> String? {
        guard let device = FuseVolume.mountedFileSystems().first(where: { $0.mountPoint == mountPoint })?.device,
              device.hasPrefix("/dev/") else { return nil }
        return String(device.dropFirst(5))
    }
}
