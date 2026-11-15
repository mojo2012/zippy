import AppKit
import UserNotifications

/// Notification Center messages, styled like the system messages shown when a
/// drive is ejected (apps can't trigger those system messages themselves).
///
/// The app asks for permission the first time an archive is opened
/// (``requestPermission()``); the FUSE helper process posts after the eject
/// (``post(title:body:reveal:)``). Clicking the notification launches Zippy,
/// which reveals the file in Finder.
enum Notifier {
    /// `userInfo` key holding the path to reveal in Finder on click.
    static let revealKey = "reveal"

    /// The system only asks the first time; after that the user's setting applies.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { log.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)") }
            log.info("Notifications allowed: \(granted)")
        }
    }

    private final class DeliveryFlag: @unchecked Sendable { var delivered = false }

    /// Posts a notification and blocks until it has been handed over (the helper
    /// process exits right afterwards). If notifications are off, shows an alert
    /// instead so an error doesn't go unnoticed. Call from the main thread only.
    static func post(title: String, body: String, reveal: URL?) {
        let center = UNUserNotificationCenter.current()
        let flag = DeliveryFlag()
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
                if let error { log.error("Posting notification failed: \(error.localizedDescription, privacy: .public)") }
                flag.delivered = error == nil
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 5)
        if !flag.delivered {
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
        alert.addButton(withTitle: String(localized: "OK"))
        if reveal != nil { alert.addButton(withTitle: String(localized: "Show in Finder")) }
        if alert.runModal() == .alertSecondButtonReturn, let reveal {
            NSWorkspace.shared.activateFileViewerSelecting([reveal])
        }
    }
}
