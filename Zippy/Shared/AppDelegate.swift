import AppKit
import ArchiveCore
import os
import UserNotifications

let log = Logger(subsystem: "dev.zippy.Zippy", category: "app")

/// Zippy-App ohne Fenster. Lebt nur, bis die angefragten Volumes bereit sind:
///
/// - Doppelklick / „Öffnen mit“ → ``application(_:open:)``
/// - Archive nacheinander an den ``ArchiveMounting`` geben (gleichzeitige Mounts
///   verträgt nicht jede Technik)
/// - Finder-Fenster öffnen, wie bei einer .dmg
/// - alles erledigt → App beendet sich; die Volumes bleiben, bis sie ausgeworfen werden
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mounter = Variant.makeMounter()

    /// Archive, die noch gemountet werden sollen.
    private var waiting: [URL] = []
    private var busy = false
    /// Finder-Fenster, deren Öffnen noch nicht bestätigt ist.
    private var openingWindows = 0
    private var receivedFiles = false
    /// Einstellungsfenster offen: nicht beenden, auch wenn alle Archive gemountet sind.
    private var settingsOpen = false
    /// Laufende Finder-Dienste (Passwort setzen/entfernen).
    private var servicesRunning = 0

    // MARK: Lebenszyklus

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Vor application(_:open:), damit Reste keine Namen blockieren.
        mounter.cleanUp()
        // Muss vor dem Ende des Starts stehen, sonst geht ein Klick auf eine Mitteilung verloren
        UNUserNotificationCenter.current().delegate = self
        // Finder-Dienste (Info.plist NSServices): Passwort setzen/entfernen
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Durch Klick auf eine Mitteilung gestartet: das erledigt der Delegate unten.
        if notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] != nil {
            receivedFiles = true
        }
        // Ohne Datei gestartet (z. B. Doppelklick auf die App): Einstellungen zeigen und
        // beim Schließen beenden; ohne Einstellungen (FSKit-Variante) kurz erklären.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard !receivedFiles else { return }
            if Variant.showSettings(onClose: { [self] in
                settingsOpen = false
                quitIfDone()
            }) {
                settingsOpen = true
                return
            }
            alert(String(localized: "Zippy opens ZIP, TAR, 7z and RAR archives as drives."),
                  info: String(localized: "Double-click an archive, or choose Open With → Zippy in Finder."))
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedFiles = true
        Notifier.requestPermission()   // für Meldungen beim Speichern nach dem Auswerfen
        if let missing = mounter.missingComponent {
            showMissing(missing)
            return quitIfDone()
        }
        // Geteilte Archive: jeder Teil steht für den ganzen Satz, gemerkt wird der erste.
        // Mehrere markierte Teile desselben Archivs ergeben so nur ein Volume.
        for url in urls.map(ArchiveParts.firstPart(of:)) where !waiting.contains(url) {
            waiting.append(url)
        }
        startNext()
    }

    // MARK: Mounten

    private func startNext() {
        guard !busy else { return }
        guard !waiting.isEmpty else { return quitIfDone() }
        let archive = waiting.removeFirst()
        busy = true
        Task {
            do {
                if let existing = mounter.mountedVolume(for: archive) {
                    showInFinder(existing)   // schon gemountet: nur das Fenster zeigen
                    busy = false
                    return startNext()
                }
                let password = try await PasswordPrompt.password(for: archive)
                let mountPoint = try await mounter.mount(archive, password: password)
                log.info("bereit: \(mountPoint.path, privacy: .public)")
                showInFinder(mountPoint)
            } catch is PasswordPrompt.Cancelled {
                // Nutzer hat die Passwortabfrage abgebrochen: still überspringen
            } catch {
                alert(String(localized: "“\(archive.lastPathComponent)” can’t be opened."), info: error.localizedDescription)
            }
            busy = false
            startNext()
        }
    }

    /// Öffnet ein Finder-Fenster für das Volume. Die App beendet sich erst, wenn
    /// der Finder das Öffnen bestätigt hat.
    private func showInFinder(_ mountPoint: URL) {
        openingWindows += 1
        NSWorkspace.shared.open(mountPoint, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("Finder-Fenster: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self.openingWindows -= 1
                self.quitIfDone()
            }
        }
    }

    private func quitIfDone() {
        if !busy && waiting.isEmpty && openingWindows == 0 && !settingsOpen && servicesRunning == 0 {
            NSApp.terminate(nil)
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

    private func showMissing(_ missing: (name: String, downloadURL: URL)) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Zippy needs \(missing.name).")
        alert.informativeText = String(localized: "\(missing.name) provides the drives and is free. Afterwards, open the archive again.")
        alert.addButton(withTitle: String(localized: "Get \(missing.name)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(missing.downloadURL)
        }
    }
}

// MARK: - Mitteilungen

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Klick auf eine Mitteilung des Hilfsprozesses: Datei im Finder zeigen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo[Notifier.revealKey] as? String
        await MainActor.run {
            receivedFiles = true
            if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            quitIfDone()
        }
    }

    /// Kommt eine Mitteilung, während Zippy läuft, trotzdem anzeigen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Finder-Dienste

extension AppDelegate {
    /// Rechtsklick → Dienste → „Passwort mit Zippy festlegen …“ (nur ZIP).
    @objc(setPassword:userData:error:)
    func setPassword(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        runService(.set, pasteboard)
    }

    /// Rechtsklick → Dienste → „Passwort mit Zippy entfernen“ (ZIP, 7z).
    @objc(removePassword:userData:error:)
    func removePassword(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        runService(.remove, pasteboard)
    }

    private func runService(_ action: PasswordChanger.Action, _ pasteboard: NSPasteboard) {
        receivedFiles = true   // kein Einstellungsfenster
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        log.info("Dienst \(action == .set ? "Passwort setzen" : "Passwort entfernen", privacy: .public): \(urls.map(\.lastPathComponent), privacy: .public)")
        servicesRunning += 1
        Task {
            for url in urls {
                await PasswordChanger.run(action, on: url) { mounter.mountedVolume(for: $0) != nil }
            }
            servicesRunning -= 1
            quitIfDone()
        }
    }
}
