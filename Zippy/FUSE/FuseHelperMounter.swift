import ArchiveCore
import Foundation
import FuseMount

/// Mounts via FUSE-T (FSKit or NFS) or macFUSE. One helper process per archive
/// (``ServeCommand``) serves the volume on its main thread and exits when it is ejected.
@MainActor
final class FuseHelperMounter: ArchiveMounting {
    /// Default: FUSE-T via FSKit when possible, otherwise via NFS. Override with
    /// `defaults write ~/Library/Preferences/dev.zippy.Zippy.plist Backend fuse-t|fuse-t-fskit|macfuse`.
    static let backendKey = "Backend"
    /// Read on every mount: the settings window may change it in the meantime.
    private var backend: FuseBackend {
        FuseBackend.choose(setting: UserDefaults.standard.string(forKey: Self.backendKey))
    }
    private let stateDirectory = ZippyPaths.stateDirectory
    /// Mount point names handed out during this run.
    private var reservedNames: Set<String> = []

    var missingComponent: (name: String, downloadURL: URL)? {
        backend.isInstalled ? nil : (backend.displayName, backend.downloadURL)
    }

    func mountedVolume(for archive: URL) -> URL? {
        let archivePath = archive.standardizedFileURL.path
        // Also check the mount table: after ejecting, the helper keeps running briefly to save
        let mounted = Set(FuseVolume.mountedPaths())
        return VolumeRecord.all(in: stateDirectory)
            .first(where: { $0.archive == archivePath && $0.isAlive && mounted.contains($0.mountPoint) })
            .map { URL(fileURLWithPath: $0.mountPoint) }
    }

    func mount(_ archive: URL, password: String?) async throws -> URL {
        let archivePath = archive.standardizedFileURL.path
        let name = Archive.volumeName(for: archive)
        let backend = await usableBackend()
        do {
            return try await mount(archivePath, name: name, password: password, backend: backend)
        } catch let failure as MountFailure where backend == .fuseTFSKit {
            // Usually FUSE-T's FSKit extension is turned off in System Settings. FSKit
            // doesn't tell other apps whether it is on, so this is the first we learn of it.
            log.info("FSKit mount failed (\(failure.message, privacy: .public)), falling back to NFS")
            return try await mount(archivePath, name: name, password: password, backend: .fuseT)
        }
    }

    /// The volume itself didn't appear (as opposed to, say, an unreadable archive).
    private struct MountFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func mount(_ archivePath: String, name: String, password: String?, backend: FuseBackend) async throws -> URL {
        let mountPoint = uniqueMountPoint(for: name, backend: backend)

        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = [ServeCommand.flag, backend.rawValue, archivePath, mountPoint.path, name]
        // Password via stdin, not as an argument: arguments are visible to every process.
        let input = Pipe()
        helper.standardInput = input
        helper.standardError = FileHandle.nullDevice
        let output = Pipe()
        helper.standardOutput = output

        // The helper's first line: READY, MOUNTFAILED <text> or ERROR <text>.
        // Exiting before that counts as an error.
        let line: String = try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?
                    .split(separator: "\n").first.map(String.init) else { return }
                handle.readabilityHandler = nil
                once.resume(returning: line)
            }
            helper.terminationHandler = { process in
                once.resume(returning: ServeCommand.errorPrefix + String(localized: "The helper process ended (\(Int(process.terminationStatus)))."))
            }
            do {
                try helper.run()
                log.info("Helper process \(helper.processIdentifier) for \(name, privacy: .public)")
                try? input.fileHandleForWriting.write(contentsOf: Data((password ?? "").utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                once.resume(throwing: error)
            }
        }

        guard line == ServeCommand.ready else {
            try? FileManager.default.removeItem(at: mountPoint)
            reservedNames.remove(mountPoint.lastPathComponent)
            if line.hasPrefix(ServeCommand.mountFailedPrefix) {
                throw MountFailure(message: String(line.dropFirst(ServeCommand.mountFailedPrefix.count)))
            }
            let message = line.hasPrefix(ServeCommand.errorPrefix) ? String(line.dropFirst(ServeCommand.errorPrefix.count)) : line
            throw MountError(message: message)
        }
        return mountPoint
    }

    /// FUSE-T via FSKit only if /Volumes/Zippy is available (set up the first time,
    /// with an administrator password). Otherwise NFS.
    private func usableBackend() async -> FuseBackend {
        guard backend == .fuseTFSKit else { return backend }
        if VolumesFolder.isUsable { return .fuseTFSKit }
        if !VolumesFolder.isInstalled, !VolumesFolder.wasDeclined, await VolumesFolder.install() {
            return .fuseTFSKit
        }
        log.info("\(VolumesFolder.url.path, privacy: .public) is missing, falling back to NFS")
        return .fuseT
    }

    /// "Name", or "Name 2", "Name 3" … if already taken.
    private func uniqueMountPoint(for name: String, backend: FuseBackend) -> URL {
        let mountDirectory = backend.mountDirectory(stateDirectory: stateDirectory, volumesFolder: VolumesFolder.url)
        let name = backend.directoryName(for: name)
        var candidate = name
        var counter = 2
        while reservedNames.contains(candidate)
                || FileManager.default.fileExists(atPath: mountDirectory.appendingPathComponent(candidate).path) {
            candidate = backend == .macFUSE ? "\(name)-\(counter)" : "\(name) \(counter)"
            counter += 1
        }
        reservedNames.insert(candidate)
        return mountDirectory.appendingPathComponent(candidate, isDirectory: true)
    }

    /// Removes leftovers of crashed helper processes. Running ones are left alone.
    func cleanUp() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let records = VolumeRecord.all(in: stateDirectory)
        let alive = Set(records.filter(\.isAlive).map(\.mountPoint))
        let mounted = Set(FuseVolume.mountedPaths())

        for record in records where !record.isAlive {
            if mounted.contains(record.mountPoint) { Darwin.unmount(record.mountPoint, MNT_FORCE) }
            rmdir(record.mountPoint)   // only if empty (e.g. in /Volumes/Zippy)
            record.remove()
        }
        let entries = (try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension != "zippy" {
            let path = entry.path
            guard !alive.contains(path) else { continue }
            if mounted.contains(path) { Darwin.unmount(path, MNT_FORCE) }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Resumes a continuation exactly once (both output and process exit may arrive).
final class Once<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(returning value: T) {
        lock.withLock { continuation.take() }?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.withLock { continuation.take() }?.resume(throwing: error)
    }
}
