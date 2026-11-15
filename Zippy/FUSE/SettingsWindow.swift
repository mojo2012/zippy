import AppKit
import FSKit
import FuseMount

/// Settings shown when Zippy is launched without an archive: which technology provides
/// the drives, and which of them are installed. Closing the window quits the app.
///
/// A System Settings pane (`.prefPane`) worked too, but went blank after switching
/// away and coming back.
///
/// Strings are English, translated in `Zippy/Resources/Localizable.xcstrings`.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onClose: () -> Void
    private var radios: [(button: NSButton, backend: FuseBackend?)] = []
    /// Rebuilt on every ``refresh()``.
    private let statusContainer = NSStackView()
    private var statusRows: [(ok: Bool?, text: String, button: (String, Selector)?)] = []
    private let defaults = UserDefaults.standard

    /// Content width (without margins). Wrapping text needs a known width, hence fixed;
    /// status texts get whatever is left next to the symbol and button.
    private let contentWidth: CGFloat = 540

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Zippy"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // With a view controller, Auto Layout sizes the window from its content,
        // with equal margins left and right
        let controller = NSViewController()
        controller.view = makeContent()
        window.contentViewController = controller
        refresh()
    }

    func show() {
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    /// Back in the app (e.g. from System Settings): check the status again.
    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    // MARK: Content

    private func makeContent() -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ])

        content.addArrangedSubview(header())
        content.addArrangedSubview(sectionTitle(String(localized: "How drives are provided")))
        for (title, backend) in options() {
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(choose(_:)))
            button.isEnabled = backend.map(\.isInstalled) ?? true
            radios.append((button, backend))
            content.addArrangedSubview(button)
        }
        content.addArrangedSubview(note(String(localized: "Applies to the next archive you open. Mounted archives stay as they are.")))
        content.addArrangedSubview(sectionTitle(String(localized: "Status")))
        // Status and "Done" share one grid, so all buttons line up in the same column
        content.addArrangedSubview(statusContainer)
        content.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        statusContainer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return container
    }

    private func options() -> [(String, FuseBackend?)] {
        let automatic = FuseBackend.choose(setting: nil)
        return [
            (String(localized: "Automatic (currently \(title(of: automatic)))"), nil),
            (String(localized: "\(title(of: .fuseTFSKit)) – drives under Locations, macOS 26 or later"), .fuseTFSKit),
            (String(localized: "\(title(of: .fuseT)) – listed under the server “fuse-t”"), .fuseT),
            (String(localized: "\(title(of: .macFUSE)) – only one archive at a time"), .macFUSE),
        ]
    }

    private func title(of backend: FuseBackend) -> String {
        switch backend {
        case .fuseTFSKit: String(localized: "FUSE-T via FSKit")
        case .fuseT: String(localized: "FUSE-T via network share (NFS)")
        case .macFUSE: "macFUSE"
        }
    }

    private func header() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let text = NSTextField(wrappingLabelWithString:
            String(localized: "Zippy opens ZIP, TAR, 7z and RAR archives as drives in Finder. The drives are provided by FUSE-T or macFUSE.")
            + "\n" + String(localized: "Version \(version)"))
        text.preferredMaxLayoutWidth = contentWidth - 64 - 14
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
        label.preferredMaxLayoutWidth = contentWidth
        return label
    }

    // MARK: State

    private func refresh() {
        let current = defaults.string(forKey: FuseHelperMounter.backendKey).flatMap(FuseBackend.init(rawValue:))
        for (button, backend) in radios {
            button.state = backend == current ? .on : .off
        }

        statusRows = []
        let install = String(localized: "Install…")
        let fuseT = FuseBackend.fuseT.isInstalled
        addStatus(fuseT, fuseT ? String(localized: "FUSE-T is installed.")
                               : String(localized: "FUSE-T is missing. Without FUSE-T or macFUSE, Zippy can’t open anything."),
                  button: (install, #selector(openFuseT)))

        if !FuseBackend.macFUSE.isInstalled {
            addStatus(nil, String(localized: "macFUSE is not installed (optional)."), button: (install, #selector(openMacFUSE)))
        } else if Self.isRegistered(module: "io.macfuse.app.fsmodule.macfuse") {
            addStatus(true, String(localized: "macFUSE is installed and its FSKit extension is registered."),
                      button: (install, #selector(openMacFUSE)))
        } else {
            // Without its FSKit extension, macFUSE falls back to its kernel extension, which
            // on Apple silicon only loads with reduced security
            addStatus(false, String(localized: "macFUSE is installed, but its FSKit extension is not registered, so macFUSE wants to load its kernel extension instead. To fix this, reinstall macFUSE and turn it on under File System Extensions."),
                      button: (install, #selector(openMacFUSE)))
        }

        if ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
            let extensions = String(localized: "Extensions…")
            if Self.isRegistered(module: "org.fuset.fskit-srv.module") {
                addStatus(true, String(localized: "The FSKit component of FUSE-T is installed. It must be turned on under File System Extensions."),
                          button: (extensions, #selector(openExtensions)))
            } else {
                addStatus(false, String(localized: "The FSKit component of FUSE-T (fuse-t.app) is missing. Reinstall FUSE-T on macOS 26 or later."),
                          button: (extensions, #selector(openExtensions)))
            }
            if VolumesFolder.isUsable {
                addStatus(true, String(localized: "The folder /Volumes/Zippy is set up."))
            } else if VolumesFolder.wasDeclined {
                addStatus(false, String(localized: "Setting up /Volumes/Zippy was declined, so Zippy uses NFS."),
                          button: (String(localized: "Ask Again"), #selector(askAgain)))
            } else {
                addStatus(nil, String(localized: "The folder /Volumes/Zippy is set up the first time you open an archive (administrator password)."))
            }
        } else {
            addStatus(nil, String(localized: "FUSE-T via FSKit needs macOS 26 or later."))
        }
        buildStatusGrid()
    }

    /// Whether a file system extension is registered. FSKit doesn't show other apps'
    /// modules to an app, but `pluginkit` does.
    private static func isRegistered(module identifier: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", identifier]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output.contains(identifier)
    }

    /// `ok`: green, orange, or neutral (nil).
    private func addStatus(_ ok: Bool?, _ text: String, button: (String, Selector)? = nil) {
        statusRows.append((ok, text, button))
    }

    /// Three columns: symbol, text, button. Last row: hint and "Done". All buttons are
    /// equally wide in the same column, so they share the same right margin.
    private func buildStatusGrid() {
        statusContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        var buttons: [NSButton] = []
        var labels: [NSTextField] = []
        for row in statusRows {
            let symbol = switch row.ok {
            case true?: ("checkmark.circle.fill", NSColor.systemGreen)
            case false?: ("exclamationmark.triangle.fill", NSColor.systemOrange)
            case nil: ("info.circle", NSColor.secondaryLabelColor)
            }
            let image = NSImageView(image: NSImage(systemSymbolName: symbol.0, accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = symbol.1
            let label = NSTextField(wrappingLabelWithString: row.text)
            labels.append(label)
            var cell: NSView = NSGridCell.emptyContentView
            if let (title, action) = row.button {
                let button = NSButton(title: title, target: self, action: action)
                buttons.append(button)
                cell = button
            }
            grid.addRow(with: [image, label, cell]).yPlacement = .center
        }

        let done = NSButton(title: String(localized: "Done"), target: window, action: #selector(NSWindow.performClose(_:)))
        done.keyEquivalent = "\r"
        buttons.append(done)
        let hint = note(String(localized: "Open archives by double-clicking them, or in Finder with Open With → Zippy."))
        labels.append(hint)
        let footer = grid.addRow(with: [NSGridCell.emptyContentView, hint, done])
        footer.yPlacement = .center
        footer.topPadding = 12

        // Columns: symbol 18 pt, buttons as wide as the widest, text gets the rest
        let buttonWidth = buttons.map(\.intrinsicContentSize.width).max() ?? 0
        let textWidth = contentWidth - 18 - buttonWidth - 2 * grid.columnSpacing
        for label in labels { label.preferredMaxLayoutWidth = textWidth }
        grid.column(at: 0).width = 18
        grid.column(at: 0).xPlacement = .center
        grid.column(at: 1).width = textWidth
        grid.column(at: 2).width = buttonWidth
        grid.column(at: 2).xPlacement = .fill
        statusContainer.addArrangedSubview(grid)
    }

    // MARK: Actions

    @objc private func choose(_ sender: NSButton) {
        let backend = radios.first { $0.button === sender }?.backend
        defaults.set(backend?.rawValue, forKey: FuseHelperMounter.backendKey)
        refresh()
    }

    @objc private func askAgain() {
        VolumesFolder.wasDeclined = false
        refresh()
    }

    @objc private func openFuseT() {
        NSWorkspace.shared.open(FuseBackend.fuseT.downloadURL)
    }

    @objc private func openMacFUSE() {
        NSWorkspace.shared.open(FuseBackend.macFUSE.downloadURL)
    }

    @objc private func openExtensions() {
        if #available(macOS 27, *) {
            _ = FSClient.shared.openFileSystemExtensionsSettings()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
    }
}
