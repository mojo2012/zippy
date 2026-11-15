import ArchiveCore
import Foundation
import FuseMount

/// Mountet über FUSE-T (FSKit oder NFS) oder macFUSE. Pro Archiv ein Hilfsprozess
/// (``ServeCommand``), der das Volume im Haupt-Thread bereitstellt und sich beim
/// Auswerfen beendet.
@MainActor
final class FuseHelperMounter: ArchiveMounting {
    /// Standard: FUSE-T über FSKit, wenn möglich, sonst über NFS. Fest einstellen mit
    /// `defaults write ~/Library/Preferences/dev.zippy.Zippy.plist Backend fuse-t|fuse-t-fskit|macfuse`.
    static let backendKey = "Backend"
    /// Bei jedem Mounten neu gelesen: Das Einstellungsfenster kann es währenddessen ändern.
    private var backend: FuseBackend {
        FuseBackend.choose(setting: UserDefaults.standard.string(forKey: Self.backendKey))
    }
    private let stateDirectory = ZippyPaths.stateDirectory
    /// In diesem Lauf vergebene Namen.
    private var reservedNames: Set<String> = []

    var missingComponent: (name: String, downloadURL: URL)? {
        backend.isInstalled ? nil : (backend.displayName, backend.downloadURL)
    }

    func mountedVolume(for archive: URL) -> URL? {
        let archivePath = archive.standardizedFileURL.path
        // Auch eingehängt: Nach dem Auswerfen läuft der Hilfsprozess noch kurz weiter (Speichern)
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
            // Meist ist die FSKit-Erweiterung von FUSE-T in den Systemeinstellungen aus.
            // Ob sie an ist, verrät FSKit fremden Apps nicht, darum erst hier.
            log.info("FSKit-Mount gescheitert (\(failure.message, privacy: .public)), nutze NFS")
            return try await mount(archivePath, name: name, password: password, backend: .fuseT)
        }
    }

    /// Das Volume selbst ist nicht erschienen (anders als z. B. ein unlesbares Archiv).
    private struct MountFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func mount(_ archivePath: String, name: String, password: String?, backend: FuseBackend) async throws -> URL {
        let mountPoint = uniqueMountPoint(for: name, backend: backend)

        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = [ServeCommand.flag, backend.rawValue, archivePath, mountPoint.path, name]
        // Passwort über stdin, nicht als Argument: Argumente sind für alle Prozesse sichtbar.
        let input = Pipe()
        helper.standardInput = input
        helper.standardError = FileHandle.nullDevice
        let output = Pipe()
        helper.standardOutput = output

        // Erste Zeile des Hilfsprozesses: READY, MOUNTFAILED <text> oder ERROR <text>.
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
                once.resume(returning: "ERROR " + String(localized: "The helper process ended (\(Int(process.terminationStatus)))."))
            }
            do {
                try helper.run()
                log.info("Hilfsprozess \(helper.processIdentifier) für \(name, privacy: .public)")
                try? input.fileHandleForWriting.write(contentsOf: Data((password ?? "").utf8))
                try? input.fileHandleForWriting.close()
            } catch {
                once.resume(throwing: error)
            }
        }

        guard line == "READY" else {
            try? FileManager.default.removeItem(at: mountPoint)
            reservedNames.remove(mountPoint.lastPathComponent)
            if line.hasPrefix("MOUNTFAILED ") { throw MountFailure(message: String(line.dropFirst(12))) }
            throw MountError(message: line.hasPrefix("ERROR ") ? String(line.dropFirst(6)) : line)
        }
        return mountPoint
    }

    /// FUSE-T über FSKit nur, wenn /Volumes/Zippy bereitsteht (beim ersten Mal mit
    /// Admin-Passwort eingerichtet). Sonst NFS.
    private func usableBackend() async -> FuseBackend {
        guard backend == .fuseTFSKit else { return backend }
        if VolumesFolder.isUsable { return .fuseTFSKit }
        if !VolumesFolder.isInstalled, !VolumesFolder.wasDeclined, await VolumesFolder.install() {
            return .fuseTFSKit
        }
        log.info("\(VolumesFolder.url.path, privacy: .public) fehlt, nutze NFS")
        return .fuseT
    }

    /// "Name", sonst "Name 2", "Name 3" … wenn schon belegt.
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

    /// Reste von abgestürzten Hilfsprozessen entfernen. Laufende bleiben unberührt.
    func cleanUp() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let records = VolumeRecord.all(in: stateDirectory)
        let alive = Set(records.filter(\.isAlive).map(\.mountPoint))
        let mounted = Set(FuseVolume.mountedPaths())

        for record in records where !record.isAlive {
            if mounted.contains(record.mountPoint) { Darwin.unmount(record.mountPoint, MNT_FORCE) }
            rmdir(record.mountPoint)   // nur, wenn leer (z. B. in /Volumes/Zippy)
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
