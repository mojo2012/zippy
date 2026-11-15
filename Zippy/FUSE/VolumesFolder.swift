import Foundation

/// `/Volumes/Zippy`: parent folder of the mount points for FUSE-T via FSKit.
///
/// Finder only shows FSKit volumes in the sidebar, on the desktop and with an eject
/// button when they are mounted under /Volumes. Only root may create folders there,
/// and macOS cleans up /Volumes at startup. So a small LaunchDaemon (no binary of its
/// own, just `mkdir`) creates the folder at every boot: world-writable with the sticky
/// bit like /tmp, so users can only remove their own mount points. It is installed
/// once, with an administrator password.
enum VolumesFolder {
    static let url = URL(fileURLWithPath: "/Volumes/Zippy", isDirectory: true)
    static let label = "dev.zippy.volumes-folder"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    /// Users who declined the setup aren't asked again.
    static let declinedKey = "VolumesFolderDeclined"

    /// Whether the folder exists and is writable.
    static var isUsable: Bool { access(url.path, W_OK) == 0 }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static var wasDeclined: Bool {
        get { UserDefaults.standard.bool(forKey: declinedKey) }
        set { UserDefaults.standard.set(newValue, forKey: declinedKey) }
    }

    /// Installs the daemon and starts it right away, asking for an administrator password.
    /// Returns `true` if the folder is usable afterwards.
    static func install() async -> Bool {
        let daemon: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/sh", "-c", "/bin/mkdir -p '\(url.path)' && /bin/chmod 1777 '\(url.path)'"],
            "RunAtLoad": true,
            // Makes Login Items show Zippy instead of "sh"
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "dev.zippy.Zippy"],
        ]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: daemon, format: .xml, options: 0)
            try data.write(to: temporary)
        } catch {
            log.error("LaunchDaemon: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        // bootout fails if the daemon isn't loaded yet; that's fine
        let shell = "/usr/bin/install -m 644 -o root -g wheel '\(temporary.path)' '\(plistPath)'"
            + " && { /bin/launchctl bootout system/\(label) 2>/dev/null; /bin/launchctl bootstrap system '\(plistPath)'; }"
        // Strip quotes: the prompt is embedded in an AppleScript string
        let prompt = String(localized: "Zippy wants to set up the folder /Volumes/Zippy once, so archives appear as drives in Finder.")
            .replacingOccurrences(of: "\"", with: "")
        let script = "do shell script \"\(shell)\" with prompt \"\(prompt)\" with administrator privileges"

        let status: Int32 = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return -1 }
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        guard status == 0 else {
            log.info("Setting up \(url.path, privacy: .public) was declined or failed (\(status))")
            wasDeclined = true
            return false
        }

        // The daemon runs immediately on bootstrap
        for _ in 0..<40 where !isUsable {
            try? await Task.sleep(for: .milliseconds(50))
        }
        log.info("\(url.path, privacy: .public) set up: \(isUsable)")
        return isUsable
    }
}
