import AppKit
import ArchiveCore

/// Obtains the password for an archive before it is mounted:
/// 1. archive without encrypted files → no password needed
/// 2. password in the keychain and it's correct → use it
/// 3. otherwise ask until it's correct or the user cancels
///
/// Every password is verified by extracting the smallest encrypted file, so a
/// wrong password never ends up in a volume.
@MainActor
enum PasswordPrompt {
    struct Cancelled: Error {}

    /// `nil` if the archive needs no password. Throws ``Cancelled`` if the user cancels.
    static func password(for archive: URL) async throws -> String? {
        let needsPassword = try await Task.detached {
            do {
                return try Archive(url: archive).needsPassword
            } catch ArchiveError.passwordRequired {
                return true   // 7z with encrypted file names: can't even be listed without a password
            }
        }.value
        guard needsPassword else { return nil }

        if let stored = storedPassword(for: archive), await isCorrect(stored, for: archive) {
            return stored
        }

        var problem: String?
        while true {
            guard let (password, remember) = ask(
                String(localized: "“\(archive.lastPathComponent)” is password-protected."),
                info: problem ?? String(localized: "Enter the password to open the archive."), isProblem: problem != nil,
                button: String(localized: "Open"), offerRemember: true
            ) else { throw Cancelled() }
            if await isCorrect(password, for: archive) {
                if remember { storePassword(password, for: archive) }
                return password
            }
            problem = String(localized: "The password is wrong. Please try again.")
        }
    }

    /// Asks for the current password to confirm removing it. Repeats until the
    /// password is correct; `nil` if the user cancels. Deliberately ignores the
    /// keychain: typing the password is the confirmation.
    static func confirmRemoval(of archive: URL) async -> String? {
        var problem: String?
        while true {
            guard let (password, _) = ask(
                String(localized: "“\(archive.lastPathComponent)” is protected with a password."),
                info: problem ?? String(localized: "To remove the protection, enter the password. The archive is then saved without encryption."),
                isProblem: problem != nil, button: String(localized: "Remove Password"), offerRemember: false
            ) else { return nil }
            if await isCorrect(password, for: archive) { return password }
            problem = String(localized: "The password is wrong. Please try again.")
        }
    }

    private static func isCorrect(_ password: String, for archive: URL) async -> Bool {
        await Task.detached {
            do {
                try Archive(url: archive, password: password).checkPassword()
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Alert with a password field and, optionally, a "Remember in Keychain" checkbox.
    private static func ask(_ message: String, info: String, isProblem: Bool,
                            button: String, offerRemember: Bool) -> (password: String, remember: Bool)? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        if isProblem { alert.alertStyle = .warning }
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: offerRemember ? 28 : 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Password")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: offerRemember ? 54 : 24))
        accessory.addSubview(field)
        let remember = NSButton(checkboxWithTitle: String(localized: "Remember in Keychain"), target: nil, action: nil)
        if offerRemember {
            remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
            accessory.addSubview(remember)
        }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, offerRemember && remember.state == .on)
    }

    /// Asks for a new password, entered twice. `nil` if the user cancels.
    static func askNewPassword(archive: URL) -> String? {
        var problem: String?
        while true {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = String(localized: "New password for “\(archive.lastPathComponent)”")
            alert.informativeText = problem ?? String(localized: "The archive is encrypted with AES-256. Without the password, nobody can open the files, not even you.")
            if problem != nil { alert.alertStyle = .warning }
            alert.addButton(withTitle: String(localized: "Set Password"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            let first = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            first.placeholderString = String(localized: "New password")
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = String(localized: "Repeat password")
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            accessory.addSubview(first)
            accessory.addSubview(second)
            first.nextKeyView = second
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = first

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue.isEmpty {
                problem = String(localized: "The password must not be empty.")
            } else if first.stringValue != second.stringValue {
                problem = String(localized: "The passwords don’t match. Please try again.")
            } else {
                return first.stringValue
            }
        }
    }

    // MARK: Remembered passwords

    private static let keychainService = "Zippy"

    /// Keychain items are keyed by the archive's standardized path.
    private static func keychainAccount(for archive: URL) -> String { archive.standardizedFileURL.path }

    static func storedPassword(for archive: URL) -> String? {
        Keychain.load(service: keychainService, account: keychainAccount(for: archive))
    }

    static func storePassword(_ password: String, for archive: URL) {
        Keychain.save(password, service: keychainService, account: keychainAccount(for: archive),
                      label: "Zippy: \(archive.lastPathComponent)")
    }

    static func forgetPassword(for archive: URL) {
        Keychain.delete(service: keychainService, account: keychainAccount(for: archive))
    }
}
