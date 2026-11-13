import AppKit
import FuseMount
import os

private let log = Logger(subsystem: "dev.zippy.Zippy", category: "app")

/// Zippy-App ohne Fenster. Lebt nur, bis die angefragten Volumes bereit sind:
///
/// - Doppelklick / „Öffnen mit“ → ``application(_:open:)``
/// - pro Archiv ein Hilfsprozess (``ServeCommand``), der das Volume bereitstellt
/// - Hilfsprozess meldet `READY` → Finder-Fenster öffnen
/// - alles erledigt → App beendet sich; die Hilfsprozesse laufen weiter,
///   jeder bis sein Volume ausgeworfen wird
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// FUSE-Implementierung. Einstellbar mit
    /// `defaults write dev.zippy.Zippy Backend macfuse|fuse-t|auto` (Standard: auto).
    private let backend = FuseBackend.choose(setting: UserDefaults.standard.string(forKey: "Backend"))
    private let stateDirectory = ZippyPaths.stateDirectory
    private var mountDirectory: URL { backend.mountDirectory(stateDirectory: stateDirectory) }
    /// In diesem Lauf vergebene Namen.
    private var reservedNames: Set<String> = []

    /// Hilfsprozesse, die noch nicht `READY` oder einen Fehler gemeldet haben.
    private var pending: [Process] = []
    /// Archive, die noch auf ihren Hilfsprozess warten. Es wird eines nach dem anderen
    /// gemountet: macFUSE scheitert bei gleichzeitigen Mounts.
    private var waiting: [URL] = []
    /// Finder-Fenster, deren Öffnen noch nicht bestätigt ist.
    private var openingWindows = 0
    private var receivedFiles = false

    // MARK: Lebenszyklus

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Vor application(_:open:), damit Reste keine Namen blockieren.
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        cleanUpStaleVolumes()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ohne Datei gestartet (z. B. Doppelklick auf die App): kurz erklären, beenden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard !receivedFiles else { return }
            alert("Zippy öffnet ZIP-Archive als Volume.",
                  info: "Doppelklicke ein ZIP oder wähle im Finder „Öffnen mit → Zippy“.")
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        guard backend.isInstalled else {
            showBackendMissing()
            return quitIfDone()
        }
        waiting.append(contentsOf: urls)
        startNext()
    }

    // MARK: Mounten

    /// Startet den nächsten Hilfsprozess, wenn keiner mehr auf `READY` wartet.
    private func startNext() {
        while pending.isEmpty, !waiting.isEmpty {
            mount(waiting.removeFirst())
        }
        quitIfDone()
    }

    private func mount(_ url: URL) {
        let archivePath = url.standardizedFileURL.path

        // Schon gemountet: nur das Fenster zeigen.
        if let existing = VolumeRecord.all(in: stateDirectory).first(where: { $0.archive == archivePath && $0.isAlive }) {
            showInFinder(URL(fileURLWithPath: existing.mountPoint))
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let mountPoint = uniqueMountPoint(for: name)

        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = [ServeCommand.flag, backend.rawValue, archivePath, mountPoint.path, name]
        helper.standardInput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        let output = Pipe()
        helper.standardOutput = output

        // Erste Zeile des Hilfsprozesses: READY oder ERROR <text>
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8)?
                .split(separator: "\n").first.map(String.init) else { return }
            handle.readabilityHandler = nil
            Task { @MainActor in self.helper(helper, reported: line, archive: url, mountPoint: mountPoint) }
        }
        // Stirbt der Hilfsprozess, bevor er etwas meldet
        helper.terminationHandler = { process in
            Task { @MainActor in
                self.helper(process, reported: "ERROR Hilfsprozess beendet (\(process.terminationStatus))",
                            archive: url, mountPoint: mountPoint)
            }
        }

        do {
            try helper.run()
            pending.append(helper)
            log.info("Hilfsprozess \(helper.processIdentifier) für \(name, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: mountPoint)
            alert("„\(url.lastPathComponent)“ lässt sich nicht öffnen.", info: error.localizedDescription)
        }
    }

    private func helper(_ helper: Process, reported line: String, archive: URL, mountPoint: URL) {
        guard let index = pending.firstIndex(where: { $0 === helper }) else { return }   // schon erledigt
        pending.remove(at: index)

        if line == "READY" {
            showInFinder(mountPoint)
        } else {
            let message = line.hasPrefix("ERROR ") ? String(line.dropFirst(6)) : line
            try? FileManager.default.removeItem(at: mountPoint)
            alert("„\(archive.lastPathComponent)“ lässt sich nicht öffnen.", info: message)
        }
        startNext()
    }

    /// Öffnet ein Finder-Fenster für das Volume, wie bei einer .dmg.
    /// Die App beendet sich erst, wenn der Finder das Öffnen bestätigt hat.
    private func showInFinder(_ mountPoint: URL) {
        openingWindows += 1
        // Hinweis: Das löst beim ersten Mal die macOS-Abfrage „Zugriff auf
        // Netzwerk-Volumes“ für Zippy aus (FUSE-T-Volumes sind NFS-Freigaben).
        NSWorkspace.shared.open(mountPoint, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("Finder-Fenster: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self.openingWindows -= 1
                self.quitIfDone()
            }
        }
    }

    private func quitIfDone() {
        if pending.isEmpty && waiting.isEmpty && openingWindows == 0 { NSApp.terminate(nil) }
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

    // MARK: Aufräumen

    /// Reste von abgestürzten Hilfsprozessen entfernen. Laufende bleiben unberührt.
    private func cleanUpStaleVolumes() {
        let records = VolumeRecord.all(in: stateDirectory)
        let alive = Set(records.filter(\.isAlive).map(\.mountPoint))
        let mounted = Set(FuseVolume.mountedPaths())

        for record in records where !record.isAlive {
            if mounted.contains(record.mountPoint) { Darwin.unmount(record.mountPoint, MNT_FORCE) }
            record.remove()
        }
        // Übrige Mountpunkt-Ordner
        let entries = (try? FileManager.default.contentsOfDirectory(at: stateDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.pathExtension != "zippy" {
            let path = entry.path
            guard !alive.contains(path) else { continue }
            if mounted.contains(path) { Darwin.unmount(path, MNT_FORCE) }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: Hinweise

    private func alert(_ message: String, info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    private func showBackendMissing() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Zippy braucht \(backend.displayName)."
        alert.informativeText = "\(backend.displayName) stellt die Volumes bereit und ist kostenlos. Danach das ZIP erneut öffnen."
        alert.addButton(withTitle: "\(backend.displayName) laden")
        alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(backend.downloadURL)
        }
    }
}
