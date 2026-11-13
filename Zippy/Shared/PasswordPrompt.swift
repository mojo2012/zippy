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
        guard try await Task.detached(operation: { try Archive(url: archive).needsPassword }).value else {
            return nil
        }
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
            message = "Das Passwort ist falsch. Bitte erneut versuchen."
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
        alert.messageText = "„\(archive.lastPathComponent)“ ist passwortgeschützt."
        alert.informativeText = problem ?? "Gib das Passwort ein, um das Archiv zu öffnen."
        if problem != nil { alert.alertStyle = .warning }
        alert.addButton(withTitle: "Öffnen")
        alert.addButton(withTitle: "Abbrechen")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        field.placeholderString = "Passwort"
        let remember = NSButton(checkboxWithTitle: "Im Schlüsselbund sichern", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(field)
        accessory.addSubview(remember)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (field.stringValue, remember.state == .on)
    }
}
