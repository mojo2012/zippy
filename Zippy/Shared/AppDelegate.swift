import AppKit
import ArchiveCore
import os
import UserNotifications

let log = Logger(subsystem: "dev.zippy.Zippy", category: "app")

/// The windowless Zippy app. It only lives until the requested volumes are ready:
///
/// - double-click / "Open With" → ``application(_:open:)``
/// - hand the archives to the ``ArchiveMounting`` one at a time (not every backend
///   copes with concurrent mounts)
/// - open a Finder window for each volume, like a .dmg does
/// - once everything is done, quit; the volumes stay until they are ejected
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mounter = Variant.makeMounter()

    private var pendingArchives: [URL] = []
    private var isMounting = false
    /// Finder windows whose opening hasn't been confirmed yet.
    private var pendingFinderWindows = 0
    /// Launched for a concrete job (files, a notification click, a service): don't show Settings.
    private var hasJob = false
    /// Keeps the app alive while the Settings window is open.
    private var settingsOpen = false
    private var runningServices = 0

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before application(_:open:), so leftovers from earlier runs don't block volume names.
        mounter.cleanUp()
        // Must be set before launching finishes, or a click on a notification gets lost.
        UNUserNotificationCenter.current().delegate = self
        // Finder services (NSServices in Info.plist): set/remove password.
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched by clicking a notification: the delegate method below handles that.
        if notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] != nil {
            hasJob = true
        }
        // Launched without a file (e.g. by double-clicking the app): show Settings and quit
        // when it closes. Variants without Settings (FSKit) show a short explanation instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard !hasJob else { return }
            if Variant.showSettings(onClose: { [self] in
                settingsOpen = false
                quitIfDone()
            }) {
                settingsOpen = true
                return
            }
            NSAlert.show(String(localized: "Zippy opens ZIP, TAR, 7z and RAR archives as drives."),
                         info: String(localized: "Double-click an archive, or choose Open With → Zippy in Finder."))
            NSApp.terminate(nil)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        hasJob = true
        Notifier.requestPermission()   // needed for messages when saving after eject
        if let missing = mounter.missingComponent {
            showMissing(missing)
            return quitIfDone()
        }
        // Split archives: any part stands for the whole set, so we keep the first part.
        // Selecting several parts of the same archive thus yields a single volume.
        for url in urls.map(ArchiveParts.firstPart(of:)) where !pendingArchives.contains(url) {
            pendingArchives.append(url)
        }
        mountNext()
    }

    // MARK: Mounting

    private func mountNext() {
        guard !isMounting else { return }
        guard !pendingArchives.isEmpty else { return quitIfDone() }
        let archive = pendingArchives.removeFirst()
        isMounting = true
        Task {
            if let existing = mounter.mountedVolume(for: archive) {
                showInFinder(existing)   // already mounted: just show the window
            } else {
                do {
                    let password = try await PasswordPrompt.password(for: archive)
                    let mountPoint = try await mounter.mount(archive, password: password)
                    log.info("Ready: \(mountPoint.path, privacy: .public)")
                    showInFinder(mountPoint)
                } catch is PasswordPrompt.Cancelled {
                    // The user cancelled the password prompt: skip silently.
                } catch {
                    NSAlert.show(String(localized: "“\(archive.lastPathComponent)” can’t be opened."),
                                 info: error.localizedDescription)
                }
            }
            isMounting = false
            mountNext()
        }
    }

    /// Opens a Finder window for the volume. The app only quits once Finder has
    /// confirmed opening it.
    private func showInFinder(_ mountPoint: URL) {
        pendingFinderWindows += 1
        NSWorkspace.shared.open(mountPoint, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { log.error("Opening Finder window failed: \(error.localizedDescription, privacy: .public)") }
            Task { @MainActor in
                self.pendingFinderWindows -= 1
                self.quitIfDone()
            }
        }
    }

    private func quitIfDone() {
        if !isMounting && pendingArchives.isEmpty && pendingFinderWindows == 0 && !settingsOpen && runningServices == 0 {
            NSApp.terminate(nil)
        }
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

// MARK: - Notifications

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Click on a notification posted by the helper process: reveal the file in Finder.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let path = response.notification.request.content.userInfo[Notifier.revealKey] as? String
        await MainActor.run {
            hasJob = true
            if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            quitIfDone()
        }
    }

    /// Show notifications even while Zippy is running.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// MARK: - Finder services

extension AppDelegate {
    /// Right-click → Services → "Set Password with Zippy…" (ZIP only).
    @objc(setPassword:userData:error:)
    func setPassword(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        runService(.set, pasteboard)
    }

    /// Right-click → Services → "Remove Password with Zippy" (ZIP, 7z).
    @objc(removePassword:userData:error:)
    func removePassword(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        runService(.remove, pasteboard)
    }

    private func runService(_ action: PasswordChanger.Action, _ pasteboard: NSPasteboard) {
        hasJob = true
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        log.info("Service \(action == .set ? "set password" : "remove password", privacy: .public): \(urls.map(\.lastPathComponent), privacy: .public)")
        runningServices += 1
        Task {
            for url in urls {
                await PasswordChanger.run(action, on: url) { mounter.mountedVolume(for: $0) != nil }
            }
            runningServices -= 1
            quitIfDone()
        }
    }
}

// MARK: - Alerts

extension NSAlert {
    /// Shows a plain modal alert with an OK button, bringing the app to the front first.
    @MainActor static func show(_ message: String, info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
