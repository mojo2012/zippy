import Foundation
import FuseMount

/// Mountet über FUSE-T oder macFUSE. Pro Archiv ein Hilfsprozess (``ServeCommand``),
/// der das Volume im Haupt-Thread bereitstellt und sich beim Auswerfen beendet.
@MainActor
final class FuseHelperMounter: ArchiveMounting {
    /// Einstellbar mit `defaults write dev.zippy.Zippy Backend macfuse|fuse-t|auto` (Standard: auto).
    private let backend = FuseBackend.choose(setting: UserDefaults.standard.string(forKey: "Backend"))
    private let stateDirectory = ZippyPaths.stateDirectory
    private var mountDirectory: URL { backend.mountDirectory(stateDirectory: stateDirectory) }
    /// In diesem Lauf vergebene Namen.
    private var reservedNames: Set<String> = []

    var missingComponent: (name: String, downloadURL: URL)? {
        backend.isInstalled ? nil : (backend.displayName, backend.downloadURL)
    }

    func mount(_ archive: URL) async throws -> URL {
        let archivePath = archive.standardizedFileURL.path

        // Schon gemountet: vorhandenen Mountpunkt liefern.
        if let existing = VolumeRecord.all(in: stateDirectory).first(where: { $0.archive == archivePath && $0.isAlive }) {
            return URL(fileURLWithPath: existing.mountPoint)
        }

        let name = archive.deletingPathExtension().lastPathComponent
        let mountPoint = uniqueMountPoint(for: name)

        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = [ServeCommand.flag, backend.rawValue, archivePath, mountPoint.path, name]
        helper.standardInput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        let output = Pipe()
        helper.standardOutput = output

        // Erste Zeile des Hilfsprozesses: READY oder ERROR <text>.
        // Endet er vorher, gilt das als Fehler.
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
                once.resume(returning: "ERROR Hilfsprozess beendet (\(process.terminationStatus))")
            }
            do {
                try helper.run()
                log.info("Hilfsprozess \(helper.processIdentifier) für \(name, privacy: .public)")
            } catch {
                once.resume(throwing: error)
            }
        }

        guard line == "READY" else {
            try? FileManager.default.removeItem(at: mountPoint)
            throw MountError(message: line.hasPrefix("ERROR ") ? String(line.dropFirst(6)) : line)
        }
        return mountPoint
    }

    /// "Name", sonst "Name 2", "Name 3" … wenn schon belegt.
    private func uniqueMountPoint(for name: String) -> URL {
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

    /// Reste von abgestürzten Hilfsprozessen entfernen. Laufende bleiben unberührt.
    func cleanUp() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let records = VolumeRecord.all(in: stateDirectory)
        let alive = Set(records.filter(\.isAlive).map(\.mountPoint))
        let mounted = Set(FuseVolume.mountedPaths())

        for record in records where !record.isAlive {
            if mounted.contains(record.mountPoint) { Darwin.unmount(record.mountPoint, MNT_FORCE) }
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

/// Setzt eine Continuation genau einmal fort (Ausgabe und Prozessende können beide kommen).
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
