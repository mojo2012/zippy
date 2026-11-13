import Foundation

/// `/Volumes/Zippy`: Elternordner der Mountpunkte für FUSE-T über FSKit.
///
/// Der Finder zeigt FSKit-Volumes nur dann in der Seitenleiste, auf dem Schreibtisch
/// und mit Auswerfen-Knopf, wenn sie unter /Volumes hängen. Dort darf nur root Ordner
/// anlegen, und macOS räumt /Volumes beim Start auf. Darum legt ein kleiner
/// LaunchDaemon (kein eigenes Programm, nur `mkdir`) den Ordner bei jedem Start an:
/// für alle beschreibbar, mit Sticky-Bit wie /tmp, damit jeder nur eigene
/// Mountpunkte löschen kann. Eingerichtet wird er einmal, mit Admin-Passwort.
enum VolumesFolder {
    static let url = URL(fileURLWithPath: "/Volumes/Zippy", isDirectory: true)
    static let label = "dev.zippy.volumes-folder"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Wer die Einrichtung abgelehnt hat, wird nicht erneut gefragt.
    static let declinedKey = "VolumesFolderDeclined"

    /// Ordner da und beschreibbar?
    static var isUsable: Bool { access(url.path, W_OK) == 0 }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static var wasDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: declinedKey) }
        set { UserDefaults.standard.set(newValue, forKey: declinedKey) }
    }

    /// Richtet den Dienst ein und startet ihn sofort. Fragt nach dem Admin-Passwort.
    /// `true`, wenn der Ordner danach nutzbar ist.
    static func install() async -> Bool {
        let daemon: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", "/bin/mkdir -p '\(url.path)' && /bin/chmod 1777 '\(url.path)'"],
            "RunAtLoad": true,
            // Unter Anmeldeobjekte erscheint dann Zippy statt „sh“
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "dev.zippy.Zippy"],
        ]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0)
            try data.write(to: temporary)
        } catch {
            log.error("LaunchDaemon: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        // bootout scheitert, wenn der Dienst noch nicht geladen ist; das ist egal
        let shell = "/usr/bin/install -m 644 -o root -g wheel '\(temporary.path)' '\(plistPath)'"
            + " && { /bin/launchctl bootout system/\(label) 2>/dev/null; /bin/launchctl bootstrap system '\(plistPath)'; }"
        let prompt = "Zippy möchte einmalig den Ordner /Volumes/Zippy einrichten, damit Archive als Laufwerke im Finder erscheinen."
        let script = "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges"

        let status: Int32 = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else {
            log.info("Einrichtung von \(url.path, privacy: .public) abgelehnt oder gescheitert (\(status))")
            wasDeclined = true
            return false
        }

        // Der Dienst läuft beim bootstrap sofort an
        for _ in 0..<40 where !isUsable {
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.info("\(url.path, privacy: .public) eingerichtet: \(isUsable)")
        return isUsable
    }
}
