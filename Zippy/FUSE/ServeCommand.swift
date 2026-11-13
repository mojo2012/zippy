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

        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: URL(fileURLWithPath: archivePath), password: password)
        } catch {
            report("ERROR \(error.localizedDescription)")
            exit(1)
        }

        FuseVolume.serve(archive, name: name, at: mountPoint, backend: backend) { error in
            if let error {
                report("ERROR \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: mountPoint)
                exit(1)   // die Schleife kehrt ohne Mount nicht zurück
            } else {
                record.save()
                report("READY")
            }
        }

        record.remove()
        exit(0)
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
