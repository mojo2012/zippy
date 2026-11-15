import Foundation

/// An entry in the archive: file, directory or symbolic link.
///
/// IDs are stable while the archive is open. The root directory always has
/// ``ArchiveIndex/rootID`` (2, as is customary with FSKit).
public struct ArchiveEntry: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case directory
        case symlink
    }

    public let id: UInt64
    public let parentID: UInt64
    public let name: String
    public let kind: Kind
    /// Uncompressed size in bytes (0 for directories).
    public let size: UInt64
    public let modificationDate: Date
    /// Permission bits only (rwxrwxrwx), without the file type.
    public let permissions: UInt16
    /// Target of a symbolic link.
    public let symlinkTarget: String?
    /// Encrypted entries can't be read without a password.
    public let isEncrypted: Bool

    /// Position of the entry's header in the archive. `nil` for directories that only
    /// exist implicitly through a path.
    let archiveIndex: Int?

    public var isDirectory: Bool { kind == .directory }
}
