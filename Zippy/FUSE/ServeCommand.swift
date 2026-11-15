import ArchiveCore
import Foundation
import FuseMount

/// Helper process: one volume per process, FUSE loop on the main thread.
///
/// Reports one line to the app via stdout: ``ready``, or ``mountFailedPrefix`` /
/// ``errorPrefix`` followed by a message. While it runs, a ``VolumeRecord`` file
/// exists in ``ZippyPaths/stateDirectory``.
enum ServeCommand {
    static let flag = "--serve"
    static let ready = "READY"
    /// The volume didn't appear; the app then tries another backend.
    static let mountFailedPrefix = "MOUNTFAILED "
    static let errorPrefix = "ERROR "

    static func run(backend: FuseBackend, archive archivePath: String, mountPoint mountPath: String, name: String) -> Never {
        let mountPoint = URL(fileURLWithPath: mountPath, isDirectory: true)
        let record = VolumeRecord(pid: getpid(), archive: archivePath, mountPoint: mountPath)

        // On SIGTERM (e.g. logout): unmount cleanly, which ends the loop.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigterm.setEventHandler { Darwin.unmount(mountPath, 0) }
        sigterm.resume()

        // The password arrives via stdin (empty = none); the app closes the pipe afterwards.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let password = input.isEmpty ? nil : String(decoding: input, as: UTF8.self)

        let archiveURL = URL(fileURLWithPath: archivePath)
        let archive: Archive
        let stamp: EditableArchive.FileStamp
        do {
            stamp = try EditableArchive.FileStamp(of: archiveURL)
            archive = try Archive(url: archiveURL, password: password)
        } catch {
            report(errorPrefix + error.localizedDescription)
            exit(1)
        }
        // Writable if the archive can be replaced (both file and folder writable)
        let fileManager = FileManager.default
        let writable = fileManager.isWritableFile(atPath: archivePath)
            && fileManager.isWritableFile(atPath: archiveURL.deletingLastPathComponent().path)
        let files = EditableArchive(archive: archive, readOnly: !writable)

        FuseVolume.serve(files, name: name, at: mountPoint, backend: backend,
                         volumeIcon: Bundle.main.url(forResource: archive.format.iconName, withExtension: "icns")) { error in
            if let error {
                report(mountFailedPrefix + error.localizedDescription)
                try? FileManager.default.removeItem(at: mountPoint)
                exit(1)   // without a mount, the loop never returns
            } else {
                record.save()
                report(ready)
            }
        }

        // Unmounted: write the changes back to the archive now
        if files.hasChanges { save(files, to: archiveURL, stamp: stamp, name: name) }
        files.close()
        archive.close()
        record.remove()
        exit(0)
    }

    /// Replaces the original. If that isn't possible, the changes go to a copy on the
    /// desktop. Either way, anything other than a plain replace posts a notification.
    private static func save(_ files: EditableArchive, to archive: URL, stamp: EditableArchive.FileStamp, name: String) {
        do {
            let target = try files.saveReplacing(archive, ifUnchangedSince: stamp)
            log.info("Saved \(target.path, privacy: .public)")
            if target != archive {
                Notifier.post(title: String(localized: "“\(archive.lastPathComponent)” was changed in the meantime"),
                              body: String(localized: "The original stays as it is. Your changes are in “\(target.lastPathComponent)”."),
                              reveal: target)
            }
            return
        } catch {
            // Details go to the log only; the notification stays short (libarchive reports raw paths)
            log.error("Saving failed: \(error.localizedDescription, privacy: .public)")
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let copy = EditableArchive.unusedURL(like: desktop.appendingPathComponent(archive.lastPathComponent),
                                             suffix: EditableArchive.editedSuffix)
        do {
            try files.save(to: copy)
            log.info("Saved copy instead: \(copy.path, privacy: .public)")
            Notifier.post(title: String(localized: "Changes to “\(archive.lastPathComponent)” not saved"),
                          body: String(localized: "The original couldn’t be replaced. A copy with your changes is on the desktop."),
                          reveal: copy)
        } catch {
            log.error("Saving a copy failed: \(error.localizedDescription, privacy: .public)")
            Notifier.post(title: String(localized: "Changes to “\(archive.lastPathComponent)” lost"),
                          body: String(localized: "Neither the original nor a copy on the desktop could be written. Details are in the log."),
                          reveal: archive)
        }
    }

    private static func report(_ line: String) {
        // If the app is already gone, this goes nowhere (SIGPIPE is ignored).
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// Locations shared by the app and the helper processes.
enum ZippyPaths {
    /// Volume records and FUSE-T mount points. /tmp is cleared on restart.
    static let stateDirectory = URL(fileURLWithPath: "/private/tmp/Zippy-\(getuid())", isDirectory: true)
}

/// Record of a running helper process: which archive is mounted where.
/// Stored as `<mount point name>.zippy` in ``ZippyPaths/stateDirectory``.
struct VolumeRecord: Codable {
    let pid: Int32
    let archive: String
    let mountPoint: String

    var file: URL {
        ZippyPaths.stateDirectory.appendingPathComponent(URL(fileURLWithPath: mountPoint).lastPathComponent + ".zippy")
    }

    var isAlive: Bool { kill(pid, 0) == 0 }

    func save() {
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: file)
    }

    static func all(in directory: URL) -> [VolumeRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "zippy" }.compactMap {
            try? JSONDecoder().decode(VolumeRecord.self, from: Data(contentsOf: $0))
        }
    }
}
