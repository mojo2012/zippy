import AppKit
import FSKit
import FuseMount
import PreferencePanes

/// Zippys Bereich in den Systemeinstellungen, wie bei macFUSE oder Wacom (`.prefPane`).
///
/// Läuft im Prozess der Systemeinstellungen, nicht in Zippy. Darum wird die Einstellung
/// über den Pfad von Zippys Einstellungsdatei geschrieben, nicht über `UserDefaults.standard`.
/// Die App liefert die Pane mit und installiert sie beim Start ohne Archiv nach
/// `~/Library/PreferencePanes` (``PreferencePaneInstaller``).
@objc(ZippyPane)
final class ZippyPane: NSPreferencePane {
    /// Wie in `FuseHelperMounter`: Zippy liest `Backend` aus dieser Datei.
    private let domain = NSHomeDirectory() + "/Library/Preferences/dev.zippy.Zippy" as CFString
    private let backendKey = "Backend" as CFString
    private let declinedKey = "VolumesFolderDeclined" as CFString

    private var radios: [(button: NSButton, backend: FuseBackend?)] = []
    private var statusStack: NSStackView!

    override func loadMainView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 668, height: 520))
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])

        content.addArrangedSubview(header())
        content.addArrangedSubview(sectionTitle("Technik für die Laufwerke"))
        for (title, backend) in options() {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(choose(_:)))
            button.isEnabled = backend.map(\.isInstalled) ?? true
            radios.append((button, backend))
            content.addArrangedSubview(button)
        }
        content.addArrangedSubview(note("Gilt für das nächste geöffnete Archiv. Gemountete Archive bleiben, wie sie sind."))
        content.addArrangedSubview(sectionTitle("Status"))
        statusStack = NSStackView()
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6
        content.addArrangedSubview(statusStack)

        mainView = view
        refresh()
        return view
    }

    override func willSelect() { refresh() }

    // MARK: Inhalt

    private func options() -> [(String, FuseBackend?)] {
        let automatic = FuseBackend.choose(setting: nil)
        return [
            ("Automatisch (zurzeit \(title(of: automatic)))", nil),
            (title(of: .fuseTFSKit) + " – Laufwerke unter „Orte“, ab macOS 26", .fuseTFSKit),
            (title(of: .fuseT) + " – erscheinen unter dem Server „fuse-t“", .fuseT),
            (title(of: .macFUSE) + " – nur ein Archiv gleichzeitig", .macFUSE),
        ]
    }

    private func title(of backend: FuseBackend) -> String {
        switch backend {
        case .fuseTFSKit: "FUSE-T über FSKit"
        case .fuseT: "FUSE-T über Netzwerk (NFS)"
        case .macFUSE: "macFUSE"
        }
    }

    private func header() -> NSView {
        let icon = NSImageView(image: NSImage(contentsOf: bundle.url(forResource: "AppIcon", withExtension: "icns")!)
                                ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let text = NSTextField(wrappingLabelWithString:
            "Zippy öffnet ZIP-, TAR-, 7z- und RAR-Archive als Laufwerke im Finder. "
            + "Die Laufwerke stellt FUSE-T oder macFUSE bereit.\nVersion \(version)")
        text.preferredMaxLayoutWidth = 520
        let row = NSStackView(views: [icon, text])
        row.spacing = 14
        row.alignment = .centerY
        return row
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = 600
        return label
    }

    // MARK: Zustand

    private func refresh() {
        let current = (CFPreferencesCopyValue(backendKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                       as? String).flatMap(FuseBackend.init(rawValue:))
        for (button, backend) in radios {
            button.state = backend == current ? .on : .off
        }

        statusStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let fuseT = FuseBackend.fuseT.isInstalled
        let fskitApp = FileManager.default.fileExists(atPath: FuseBackend.fskitAppPath)
        let fskitPossible = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))

        addStatus(fuseT, fuseT ? "FUSE-T ist installiert." : "FUSE-T fehlt.",
                  button: fuseT ? nil : ("FUSE-T laden", #selector(openFuseT)))
        if fskitPossible {
            addStatus(fskitApp, fskitApp
                      ? "Die FSKit-Komponente von FUSE-T ist da. Sie muss unter Dateisystemerweiterungen eingeschaltet sein."
                      : "Die FSKit-Komponente von FUSE-T (fuse-t.app) fehlt. FUSE-T unter macOS 26 oder neuer neu installieren.",
                      button: fskitApp ? ("Dateisystemerweiterungen …", #selector(openExtensions)) : nil)
            let folder = FileManager.default.fileExists(atPath: "/Volumes/Zippy")
            let declined = CFPreferencesCopyValue(declinedKey, domain, kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost) as? Bool ?? false
            if folder {
                addStatus(true, "Der Ordner /Volumes/Zippy ist eingerichtet.")
            } else if declined {
                addStatus(false, "Die Einrichtung von /Volumes/Zippy wurde abgelehnt, Zippy nutzt NFS.",
                          button: ("Erneut fragen", #selector(askAgain)))
            } else {
                addStatus(nil, "Der Ordner /Volumes/Zippy wird beim ersten Öffnen eines Archivs eingerichtet (Administrator-Passwort).")
            }
        } else {
            addStatus(nil, "FUSE-T über FSKit braucht macOS 26 oder neuer.")
        }
        let macFUSE = FuseBackend.macFUSE.isInstalled
        addStatus(macFUSE ? true : nil, macFUSE ? "macFUSE ist installiert." : "macFUSE ist nicht installiert (optional).")
    }

    /// `ok`: grün, rot oder (nil) neutral.
    private func addStatus(_ ok: Bool?, _ text: String, button: (String, Selector)? = nil) {
        let symbol = switch ok {
        case true?: ("checkmark.circle.fill", NSColor.systemGreen)
        case false?: ("exclamationmark.triangle.fill", NSColor.systemOrange)
        case nil: ("info.circle", NSColor.secondaryLabelColor)
        }
        let image = NSImageView(image: NSImage(systemSymbolName: symbol.0, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = symbol.1
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 440
        var views: [NSView] = [image, label]
        if let (title, action) = button {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .push
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .firstBaseline
        statusStack.addArrangedSubview(row)
    }

    // MARK: Aktionen

    @objc private func choose(_ sender: NSButton) {
        let backend = radios.first { $0.button === sender }?.backend
        CFPreferencesSetValue(backendKey, backend?.rawValue as CFString?, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        refresh()
    }

    @objc private func askAgain() {
        CFPreferencesSetValue(declinedKey, nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        refresh()
    }

    @objc private func openFuseT() {
        NSWorkspace.shared.open(FuseBackend.fuseT.downloadURL)
    }

    @objc private func openExtensions() {
        if #available(macOS 27, *) {
            _ = FSClient.shared.openFileSystemExtensionsSettings()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
    }
}
