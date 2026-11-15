import AppKit
import ArchiveCore

/// Mounts through Zippy's own FSKit extension (ZippyFS). App Store compatible:
/// runs sandboxed and needs no third-party software, but signing the extension
/// requires a paid Apple Developer account.
///
/// Flow (macOS 15, where FSKit only works with block devices):
/// 1. create a ``ZippyImage``: APFS clone of the archive + padding + trailer with the name
/// 2. hand the image to DiskImageMounter → macOS attaches it as a device
/// 3. ZippyFS recognizes the trailer and provides the volume under /Volumes
/// 4. ejecting in Finder detaches volume and device, like a .dmg
///
/// From macOS 26 on, FSKit could mount straight from the file (`FSPathURLResource`);
/// steps 1 and 2 would go away, the interface stays the same.
@MainActor
final class FSKitMounter: ArchiveMounting {
    private let diskImageMounter = URL(fileURLWithPath: "/System/Library/CoreServices/DiskImageMounter.app")
    /// Inside the app's sandbox container.
    private let imagesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Images", isDirectory: true)
    private let timeout: Duration = .seconds(30)

    /// The extension ships inside the app; whether it's enabled only shows when mounting.
    var missingComponent: (name: String, downloadURL: URL)? { nil }

    /// FSKit volumes aren't tracked per archive: every open mounts anew.
    func mountedVolume(for archive: URL) -> URL? { nil }

    func mount(_ archive: URL, password: String?) async throws -> URL {
        let name = Archive.volumeName(for: archive)

        // Pass the password to the extension through the shared keychain, under a random
        // ID stored in the image trailer. The extension deletes the item after reading it.
        var passwordID: UUID?
        if let password {
            guard let group = Keychain.sharedGroup else {
                throw MountError(message: String(localized: "In this variant, password-protected archives need a keychain shared by the app and the extension (ZippyKeychainGroup, requires a developer account)."))
            }
            let id = UUID()
            Keychain.save(password, service: Keychain.handoffService, account: id.uuidString, accessGroup: group)
            passwordID = id
        }

        let accessing = archive.startAccessingSecurityScopedResource()
        defer { if accessing { archive.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let image = imagesDirectory.appendingPathComponent("\(name) [\(UUID().uuidString.prefix(8))].img")
        try ZippyImage.create(from: archive, at: image, name: name, passwordID: passwordID)
        // Read-only file, so DiskImageMounter attaches the image read-only too.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: image.path)

        // Start watching before DiskImageMounter runs, so the mount notification isn't missed.
        let appeared = waitForVolume(named: name)
        _ = try await NSWorkspace.shared.open([image], withApplicationAt: diskImageMounter,
                                              configuration: NSWorkspace.OpenConfiguration())
        guard let volume = await appeared.value else {
            throw MountError(message: String(localized: "The volume didn’t appear. Is the Zippy file system extension turned on? (System Settings → General → Login Items & Extensions → File System Extensions)"))
        }
        return volume
    }

    /// Waits for a newly mounted volume with this name (ZippyFS names it after the
    /// trailer). Gives up after ``timeout``.
    private func waitForVolume(named name: String) -> Task<URL?, Never> {
        let timeout = self.timeout
        let watcher = Task { @MainActor () -> URL? in
            for await notification in NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didMountNotification) {
                guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
                      let volumeName = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String
                else { continue }
                if Self.volumeName(volumeName, matches: name) { return url }
            }
            return nil   // cancelled by the timeout
        }
        Task {
            try? await Task.sleep(for: timeout)
            watcher.cancel()
        }
        return watcher
    }

    /// Deletes old images whose volume is no longer mounted.
    func cleanUp() {
        let mountedNames = Set((FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey], options: []) ?? [])
            .compactMap { try? $0.resourceValues(forKeys: [.volumeNameKey]).volumeName })
        let images = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for image in images where image.pathExtension == "img" {
            // Images are named "<volume name> [<random id>].img".
            let stem = image.deletingPathExtension().lastPathComponent
            let name = stem.components(separatedBy: " [").dropLast().joined(separator: " [")
            let stillMounted = mountedNames.contains { Self.volumeName($0, matches: name) }
            if !stillMounted { try? FileManager.default.removeItem(at: image) }
        }
    }

    /// True for `name` itself and for the " 1", " 2" … suffixes macOS adds to duplicate names.
    private nonisolated static func volumeName(_ volumeName: String, matches name: String) -> Bool {
        volumeName == name || volumeName.hasPrefix(name + " ")
    }
}
