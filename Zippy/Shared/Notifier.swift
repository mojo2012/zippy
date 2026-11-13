import AppKit
import UserNotifications

/// Mitteilungen in der Mitteilungszentrale, im Stil der System-Meldungen beim
/// Auswerfen von Laufwerken. Die System-Meldung selbst kann keine App auslösen.
///
/// Die App fragt beim ersten Öffnen um Erlaubnis (``requestPermission()``); der
/// FUSE-Hilfsprozess meldet nach dem Auswerfen (``post(title:body:reveal:)``).
/// Ein Klick auf die Mitteilung startet Zippy, das die Datei im Finder zeigt.
enum Notifier {
    /// Pfad in `userInfo`, der beim Klick im Finder gezeigt wird.
    static let revealKey = "reveal"

    /// Das System fragt nur beim ersten Mal, danach gilt die Einstellung.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log.error("Mitteilungen: \(error.localizedDescription, privacy: .public)") }
            log.info("Mitteilungen erlaubt: \(granted)")
        }
    }

    private final class Box: @unchecked Sendable { var delivered = false }

    /// Zeigt eine Mitteilung. Blockiert, bis sie übergeben ist (der Hilfsprozess
    /// endet gleich danach). Sind Mitteilungen aus, erscheint ein Dialog, damit
    /// ein Fehler nicht ungesehen bleibt. Nur vom Haupt-Thread aufrufen.
    static func post(title: String, body: String, reveal: URL?) {
        let center = UNUserNotificationCenter.current()
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        center.getNotificationSettings { settings in
            guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
                done.signal()
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let reveal { content.userInfo = [revealKey: reveal.path] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error { log.error("Mitteilung: \(error.localizedDescription, privacy: .public)") }
                box.delivered = error == nil
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
        if !box.delivered {
            MainActor.assumeIsolated { showAlert(title: title, body: body, reveal: reveal) }
        }
    }

    @MainActor private static func showAlert(title: String, body: String, reveal: URL?) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        if reveal != nil { alert.addButton(withTitle: "Im Finder zeigen") }
        if alert.runModal() == .alertSecondButtonReturn, let reveal {
            NSWorkspace.shared.activateFileViewerSelecting([reveal])
        }
    }
}
