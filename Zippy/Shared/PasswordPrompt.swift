import AppKit
import ArchiveCore

/// Besorgt das Passwort für ein Archiv, bevor es gemountet wird:
/// 1. Archiv ohne verschlüsselte Dateien → kein Passwort nötig
/// 2. Passwort im Schlüsselbund und es passt → nehmen
/// 3. sonst nachfragen, bis es passt oder abgebrochen wird
///
/// Geprüft wird jedes Passwort, indem die kleinste verschlüsselte Datei entpackt
/// wird. So landet ein falsches Passwort nie im Volume.
@MainActor
enum PasswordPrompt {
    static let keychainService = "Zippy"

    struct Cancelled: Error {}

    /// `nil`, wenn das Archiv kein Passwort braucht. Wirft ``Cancelled`` bei Abbruch.
    static func password(for archive: URL) async throws -> String? {
        let needsPassword = try await Task.detached {
            do {
                return try Archive(url: archive).needsPassword
            } catch ArchiveError.passwordRequired {
                return true   // 7z mit verschlüsselten Dateinamen: ohne Passwort nicht einmal auflistbar
            }
        }.value
        guard needsPassword else { return nil }
        let account = archive.standardizedFileURL.path

        if let stored = Keychain.load(service: keychainService, account: account),
           await isCorrect(stored, for: archive) {
            return stored
        }

        var message: String?
        while true {
            guard let (password, remember) = ask(archive: archive, problem: message) else { throw Cancelled() }
            if await isCorrect(password, for: archive) {
                if remember {
                    Keychain.save(password, service: keychainService, account: account,
                                  label: "Zippy: \(archive.lastPathComponent)")
                }
                return password
            }
            message = String(localized: "The password is wrong. Please try again.")
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

    /// Dialog mit Passwortfeld und „Im Schlüsselbund sichern“.
    private static func ask(archive: URL, problem: String?) -> (String, Bool)? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(archive.lastPathComponent)” is password-protected.")
        alert.informativeText = problem ?? String(localized: "Enter the password to open the archive.")
        if problem != nil { alert.alertStyle = .warning }
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        field.placeholderString = String(localized: "Password")
        let remember = NSButton(checkboxWithTitle: String(localized: "Remember in Keychain"), target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(remember)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, remember.state == .on)
    }

    /// Neues Passwort, zweimal eingegeben. `nil` bei Abbruch.
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
}
