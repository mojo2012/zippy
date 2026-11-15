import AppKit
import ArchiveCore

/// Passwort eines Archivs setzen, ändern oder entfernen, über die Finder-Dienste
/// (Rechtsklick → Dienste). Setzen geht nur bei ZIP (AES-256), Entfernen bei ZIP und 7z.
/// Das Archiv wird dafür neu geschrieben und das Original ersetzt.
@MainActor
enum PasswordChanger {
    enum Action { case set, remove }

    /// Was über ein Archiv bekannt ist, bevor das Passwort feststeht.
    private struct Probe: Sendable {
        let needsPassword: Bool
        let canSet: Bool
        let canRemove: Bool
        /// ZIP verschlüsselt nur Dateiinhalte; Ordner und leere Dateien bleiben offen.
        let hasContent: Bool
    }

    /// `isMounted`: Gemountete Archive nicht anfassen, sonst überschreibt das Speichern
    /// beim Auswerfen die Änderung.
    static func run(_ action: Action, on url: URL, isMounted: (URL) -> Bool) async {
        let name = url.lastPathComponent
        if isMounted(url) {
            return alert(String(localized: "“\(name)” is open as a drive."),
                         info: String(localized: "Eject it first, then try again."))
        }

        let probe: Probe
        do {
            probe = try await Task.detached {
                do {
                    let archive = try Archive(url: url)
                    defer { archive.close() }
                    return Probe(needsPassword: archive.needsPassword,
                                 canSet: archive.canSetPassword, canRemove: archive.canRemovePassword,
                                 hasContent: archive.index.entries.values.contains { $0.kind == .file && $0.size > 0 })
                } catch ArchiveError.passwordRequired {
                    // 7z mit verschlüsselten Dateinamen
                    return Probe(needsPassword: true, canSet: false, canRemove: true, hasContent: true)
                }
            }.value
        } catch {
            return alert(String(localized: "“\(name)” can’t be opened."), info: error.localizedDescription)
        }

        switch action {
        case .set where !probe.canSet:
            return alert(String(localized: "Zippy can’t protect “\(name)” with a password."),
                         info: String(localized: "Zippy can only add a password to ZIP archives."))
        case .set where !probe.hasContent:
            return alert(String(localized: "“\(name)” has nothing to encrypt."),
                         info: String(localized: "A ZIP password protects only file contents. Folders and empty files stay readable."))
        case .remove where !probe.needsPassword:
            return alert(String(localized: "“\(name)” has no password."), info: "")
        case .remove where !probe.canRemove:
            return alert(String(localized: "Zippy can’t remove the password from “\(name)”."),
                         info: String(localized: "Zippy can remove passwords from ZIP and 7z archives."))
        default:
            break
        }

        // Altes Passwort (geprüft), dann das neue
        let current: String?
        do {
            current = try await PasswordPrompt.password(for: url)
        } catch {
            return   // abgebrochen
        }
        let encryption: EditableArchive.Encryption
        switch action {
        case .set:
            guard let new = PasswordPrompt.askNewPassword(archive: url) else { return }
            encryption = .set(new)
        case .remove:
            encryption = .remove
        }

        do {
            let target = try await Task.detached {
                let stamp = try EditableArchive.FileStamp(of: url)
                let archive = try Archive(url: url, password: current)
                defer { archive.close() }
                let editable = EditableArchive(archive: archive)
                defer { editable.close() }
                return try editable.saveReplacing(url, ifUnchangedSince: stamp, encryption: encryption)
            }.value

            // Gemerktes Passwort nachziehen
            let account = target.standardizedFileURL.path
            switch encryption {
            case .set(let new) where Keychain.load(service: PasswordPrompt.keychainService, account: account) != nil:
                Keychain.save(new, service: PasswordPrompt.keychainService, account: account,
                              label: "Zippy: \(target.lastPathComponent)")
            case .remove:
                Keychain.delete(service: PasswordPrompt.keychainService, account: account)
            default:
                break
            }

            if target != url {
                alert(String(localized: "“\(name)” was changed in the meantime"),
                      info: String(localized: "The original stays as it is. Your changes are in “\(target.lastPathComponent)”."))
            } else if action == .set {
                alert(String(localized: "“\(name)” is now protected with a password."), info: "")
            } else {
                alert(String(localized: "The password of “\(name)” was removed."), info: "")
            }
        } catch {
            log.error("Passwort ändern: \(error.localizedDescription, privacy: .public)")
            alert(String(localized: "The password of “\(name)” couldn’t be changed."), info: error.localizedDescription)
        }
    }

    private static func alert(_ message: String, info: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }
}
