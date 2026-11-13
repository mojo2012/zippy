import ArchiveCore
import Foundation
import FuseMount

/// Hilfsprozess: ein Volume pro Prozess, FUSE-Schleife im Haupt-Thread.
///
/// Meldet der App über stdout eine Zeile: `READY` oder `ERROR <text>`.
/// Solange er läuft, gibt es eine ``VolumeRecord``-Datei in ``ZippyPaths/stateDirectory``.
enum ServeCommand {
    static let flag = "--serve"

    static func run(backend: FuseBackend, archive archivePath: String, mountPoint mountPath: String, name: String) -> Never {
        let mountPoint = URL(fileURLWithPath: mountPath, isDirectory: true)
        let record = VolumeRecord(pid: getpid(), archive: archivePath, mountPoint: mountPath)

        // Beenden per SIGTERM (z. B. Abmelden): sauber aushängen, dann endet die Schleife.
        signal(SIGTERM, SIG_IGN)
        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigterm.setEventHandler { Darwin.unmount(mountPath, 0) }
        sigterm.resume()

        // Passwort kommt über stdin (leer = keins). Die App schließt die Pipe danach.
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let password = input.isEmpty ? nil : String(decoding: input, as: UTF8.self)

        let archiveURL = URL(fileURLWithPath: archivePath)
        let archive: Archive
        let stamp: EditableArchive.FileStamp
        do {
            stamp = try EditableArchive.FileStamp(of: archiveURL)
            archive = try Archive(url: archiveURL, password: password)
        } catch {
            report("ERROR \(error.localizedDescription)")
            exit(1)
        }
        // Beschreibbar, wenn sich das Archiv ersetzen lässt (Datei und Ordner schreibbar)
        let fileManager = FileManager.default
        let writable = fileManager.isWritableFile(atPath: archivePath)
            && fileManager.isWritableFile(atPath: archiveURL.deletingLastPathComponent().path)
        let files = EditableArchive(archive: archive, readOnly: !writable)

        FuseVolume.serve(files, name: name, at: mountPoint, backend: backend,
                         volumeIcon: Bundle.main.url(forResource: archive.format.iconName, withExtension: "icns")) { error in
            if let error {
                // Eigene Kennung: Die App versucht dann ein anderes Backend
                report("MOUNTFAILED \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: mountPoint)
                exit(1)   // die Schleife kehrt ohne Mount nicht zurück
            } else {
                record.save()
                report("READY")
            }
        }

        // Ausgehängt: Änderungen jetzt ins Archiv schreiben
        if files.hasChanges { save(files, to: archiveURL, stamp: stamp, name: name) }
        files.close()
        archive.close()
        record.remove()
        exit(0)
    }

    /// Ersetzt das Original. Geht das nicht, landen die Änderungen als Kopie auf dem
    /// Schreibtisch; in beiden Sonderfällen kommt eine Mitteilung.
    private static func save(_ files: EditableArchive, to archive: URL, stamp: EditableArchive.FileStamp, name: String) {
        do {
            let target = try files.saveReplacing(archive, ifUnchangedSince: stamp)
            log.info("gespeichert: \(target.path, privacy: .public)")
            if target != archive {
                Notifier.post(title: "„\(archive.lastPathComponent)“ wurde zwischendurch geändert",
                              body: "Das Original bleibt, wie es ist. Deine Änderungen stehen in „\(target.lastPathComponent)“.",
                              reveal: target)
            }
            return
        } catch {
            // Details nur ins Log, die Mitteilung bleibt kurz (libarchive meldet rohe Pfade)
            log.error("Speichern fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let copy = EditableArchive.unusedURL(like: desktop.appendingPathComponent(archive.lastPathComponent),
                                             suffix: "bearbeitet")
        do {
            try files.save(to: copy)
            log.info("Ersatzkopie: \(copy.path, privacy: .public)")
            Notifier.post(title: "Änderungen an „\(archive.lastPathComponent)“ nicht gespeichert",
                          body: "Das Original ließ sich nicht ersetzen. Eine Kopie mit deinen Änderungen liegt auf dem Schreibtisch.",
                          reveal: copy)
        } catch {
            log.error("Ersatzkopie fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            Notifier.post(title: "Änderungen an „\(archive.lastPathComponent)“ verloren",
                          body: "Weder das Original noch eine Kopie auf dem Schreibtisch ließen sich schreiben. Details im Protokoll.",
                          reveal: archive)
        }
    }

    private static func report(_ line: String) {
        // Ist die App schon weg, geht das ins Leere (SIGPIPE ist ignoriert).
        try? FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// Gemeinsame Orte von App und Hilfsprozess.
enum ZippyPaths {
    /// Merkzettel und FUSE-T-Mountpunkte. /tmp wird beim Neustart geleert.
    static let stateDirectory = URL(fileURLWithPath: "/private/tmp/Zippy-\(getuid())", isDirectory: true)
}

/// Merkzettel eines laufenden Hilfsprozesses: welches Archiv wo gemountet ist.
/// Liegt als `<Volumename>.zippy` in ``ZippyPaths/stateDirectory``.
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
