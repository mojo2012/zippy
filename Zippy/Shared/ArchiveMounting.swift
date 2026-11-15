import Foundation

/// The seam between the app and the file system backend.
///
/// The app (``AppDelegate``) receives archives, calls ``mount(_:password:)``,
/// opens the mount point in Finder and quits. Only the implementation knows how
/// the volume comes about:
///
/// - `Zippy/FUSE`: FUSE-T or macFUSE, one helper process per volume
/// - `Zippy/FSKit`: Zippy image + DiskImageMounter + FSKit extension
///
/// The target alone decides which implementation ships in the app
/// (``Variant/makeMounter()``), not the code.
@MainActor
protocol ArchiveMounting {
    /// Name and download URL of a missing installable component (e.g. FUSE-T), if any.
    var missingComponent: (name: String, downloadURL: URL)? { get }

    /// Cleans up leftovers from earlier runs. Called before the first ``mount(_:password:)``.
    func cleanUp()

    /// The mount point if this archive is already mounted (then it is opened without a password prompt).
    func mountedVolume(for archive: URL) -> URL?

    /// Mounts an archive and returns the mount point once the volume is available.
    /// `password` has already been verified (``PasswordPrompt``); nil for unencrypted archives.
    func mount(_ archive: URL, password: String?) async throws -> URL
}

struct MountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
