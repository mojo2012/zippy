import AppKit
import ArchiveCore

/// Sets, changes or removes an archive's password via the Finder services
/// (right-click → Services). Setting works for ZIP only (AES-256), removing for ZIP and 7z.
/// The archive is rewritten and replaces the original.
@MainActor
enum PasswordChanger {
    enum Action { case set, remove }

    /// What is known about an archive before its password is known.
    private struct Probe: Sendable {
        let needsPassword: Bool
        let canSet: Bool
        let canRemove: Bool
        /// ZIP encrypts file contents only; folders and empty files stay readable.
        let hasContent: Bool
    }

    /// `isMounted`: mounted archives are left alone, otherwise saving on eject would
    /// overwrite the change.
    static func run(_ action: Action, on url: URL, isMounted: (URL) -> Bool) async {
        let name = url.lastPathComponent
        if isMounted(url) {
            return NSAlert.show(String(localized: "“\(name)” is open as a drive."),
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
                    // 7z with encrypted file names
                    return Probe(needsPassword: true, canSet: false, canRemove: true, hasContent: true)
                }
            }.value
        } catch {
            return NSAlert.show(String(localized: "“\(name)” can’t be opened."), info: error.localizedDescription)
        }

        switch action {
        case .set where !probe.canSet:
            return NSAlert.show(String(localized: "Zippy can’t protect “\(name)” with a password."),
                                info: String(localized: "Zippy can only add a password to ZIP archives."))
        case .set where !probe.hasContent:
            return NSAlert.show(String(localized: "“\(name)” has nothing to encrypt."),
                                info: String(localized: "A ZIP password protects only file contents. Folders and empty files stay readable."))
        case .remove where !probe.needsPassword:
            return NSAlert.show(String(localized: "“\(name)” has no password."), info: "")
        case .remove where !probe.canRemove:
            return NSAlert.show(String(localized: "Zippy can’t remove the password from “\(name)”."),
                                info: String(localized: "Zippy can remove passwords from ZIP and 7z archives."))
        default:
            break
        }

        // First the current (verified) password, then the new one.
        // nil if the archive isn't encrypted yet.
        let current: String?
        do {
            current = try await PasswordPrompt.password(for: url)
        } catch {
            return   // cancelled
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

            // Keep a remembered password in sync.
            switch encryption {
            case .set(let new) where PasswordPrompt.storedPassword(for: target) != nil:
                PasswordPrompt.storePassword(new, for: target)
            case .remove:
                PasswordPrompt.forgetPassword(for: target)
            default:
                break
            }

            if target != url {
                NSAlert.show(String(localized: "“\(name)” was changed in the meantime"),
                             info: String(localized: "The original stays as it is. Your changes are in “\(target.lastPathComponent)”."))
            } else if action == .set {
                NSAlert.show(String(localized: "“\(name)” is now protected with a password."), info: "")
            } else {
                NSAlert.show(String(localized: "The password of “\(name)” was removed."), info: "")
            }
        } catch {
            log.error("Changing password failed: \(error.localizedDescription, privacy: .public)")
            NSAlert.show(String(localized: "The password of “\(name)” couldn’t be changed."), info: error.localizedDescription)
        }
    }
}
