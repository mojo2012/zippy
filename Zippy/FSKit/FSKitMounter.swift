import AppKit
import ArchiveCore

/// Mountet über die eigene FSKit-Erweiterung (ZippyFS). App-Store-tauglich:
/// läuft in der Sandbox, braucht keine Zusatzsoftware, aber einen bezahlten
/// Apple-Developer-Account zum Signieren der Erweiterung.
///
/// Ablauf (macOS 15, FSKit nur mit Block-Geräten):
/// 1. ``ZippyImage`` anlegen: APFS-Clone des ZIPs + Auffüllen + Trailer mit Namen
/// 2. Image an DiskImageMounter übergeben → macOS hängt es als Gerät an
/// 3. ZippyFS erkennt den Trailer und stellt das Volume unter /Volumes bereit
/// 4. Auswerfen im Finder löst Volume und Gerät wie bei einer .dmg
///
/// Ab macOS 26 könnte FSKit direkt aus der Datei mounten (`FSPathURLResource`);
/// dann fallen Schritt 1 und 2 weg, die Schnittstelle bleibt.
@MainActor
final class FSKitMounter: ArchiveMounting {
    private let diskImageMounter = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
    /// Im Sandbox-Container der App.
    private let imagesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Images", isDirectory: true)
    private let timeout: Duration = .seconds(30)

    /// Die Erweiterung steckt in der App; ob sie eingeschaltet ist, zeigt sich erst beim Mounten.
    var missingComponent: (name: String, downloadURL: URL)? { nil }

    /// FSKit-Volumes werden nicht pro Archiv verwaltet: jedes Öffnen mountet neu.
    func mountedVolume(for archive: URL) -> URL? { nil }

    func mount(_ archive: URL, password: String?) async throws -> URL {
        let name = Archive.volumeName(for: archive)

        // Passwort an die Erweiterung: über den gemeinsamen Schlüsselbund, unter einer
        // zufälligen ID, die im Image-Trailer steht. Die Erweiterung löscht den Eintrag.
        var passwordID: UUID?
        if let password {
            guard let group = Keychain.sharedGroup else {
                throw MountError(message: """
                    Passwortgeschützte Archive brauchen in dieser Variante einen gemeinsamen \
                    Schlüsselbund von App und Erweiterung (ZippyKeychainGroup, nur mit Developer-Account).
                    """)
            }
            let id = UUID()
            Keychain.save(password, service: Keychain.handoffService, account: id.uuidString, accessGroup: group)
            passwordID = id
        }

        let accessing = archive.startAccessingSecurityScopedResource()
        defer { if accessing { archive.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let image = imagesDirectory.appendingPathComponent("\(name) [\(UUID().uuidString.prefix(8))].img")
        try ZippyImage.create(from: archive, at: image, name: name, passwordID: passwordID)
        // Nur lesbar: dann hängt DiskImageMounter das Image auch nur lesend an.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: image.path)

        // Auf das Volume warten, bevor DiskImageMounter loslegt, damit nichts verpasst wird.
        let appeared = waitForVolume(named: name)
        _ = try await NSWorkspace.shared.open([image], withApplicationAt: diskImageMounter,
                                              configuration: NSWorkspace.OpenConfiguration())
        guard let volume = await appeared.value else {
            throw MountError(message: """
                Das Volume ist nicht erschienen. Ist die Zippy-Dateisystemerweiterung eingeschaltet? \
                (Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Dateisystemerweiterungen)
                """)
        }
        return volume
    }

    /// Wartet auf ein neu gemountetes Volume mit diesem Namen (ZippyFS benennt es
    /// nach dem Trailer). macOS hängt bei gleichen Namen " 1", " 2" … an.
    private func waitForVolume(named name: String) -> Task<URL?, Never> {
        let timeout = self.timeout
        let watcher = Task { @MainActor () -> URL? in
            for await notification in NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didMountNotification) {
                guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                      let volumeName = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
                else { continue }
                if volumeName == name || volumeName.hasPrefix(name + " ") { return url }
            }
            return nil   // abgebrochen
        }
        Task {
            try? await Task.sleep(for: timeout)
            watcher.cancel()
        }
        return watcher
    }

    /// Alte Images löschen, deren Volume nicht mehr gemountet ist.
    func cleanUp() {
        let mountedNames = Set((FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: []) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.volumeNameKey]).volumeName })
        let images = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for image in images where image.pathExtension == "img" {
            let stem = image.deletingPathExtension().lastPathComponent
            let name = stem.components(separatedBy: " [").dropLast().joined(separator: " [")
            let stillMounted = mountedNames.contains { $0 == name || $0.hasPrefix(name + " ") }
            if !stillMounted { try? FileManager.default.removeItem(at: image) }
        }
    }
}
