import Foundation

/// Ein Eintrag im Archiv: Datei, Ordner oder symbolischer Link.
///
/// IDs sind stabil, solange das Archiv geöffnet ist. Der Wurzelordner hat
/// immer ``ArchiveIndex/rootID`` (2, wie bei FSKit üblich).
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
    /// Unkomprimierte Größe in Bytes (0 bei Ordnern).
    public let size: UInt64
    public let modificationDate: Date
    /// Nur die Rechte-Bits (rwxrwxrwx), ohne Dateityp.
    public let permissions: UInt16
    /// Ziel bei symbolischen Links.
    public let symlinkTarget: String?
    /// Verschlüsselte Einträge lassen sich ohne Passwort nicht lesen.
    public let isEncrypted: Bool

    /// Position des Eintrags im Archiv. `nil` bei Ordnern, die nur
    /// indirekt über einen Pfad existieren.
    let archiveIndex: Int?

    public var isDirectory: Bool { kind == .directory }
}
