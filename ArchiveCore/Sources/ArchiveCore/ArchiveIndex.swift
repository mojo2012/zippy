import Foundation

/// Directory tree of an archive, built once when opening.
public struct ArchiveIndex: Sendable {
    public static let rootID: UInt64 = 2

    public private(set) var entries: [UInt64: ArchiveEntry] = [:]
    private var childrenByName: [UInt64: [String: UInt64]] = [:]
    private var nextID: UInt64 = 3

    public var root: ArchiveEntry { entries[Self.rootID]! }

    public func entry(_ id: UInt64) -> ArchiveEntry? { entries[id] }

    /// Children of a directory, sorted by name.
    public func children(of id: UInt64) -> [ArchiveEntry] {
        (childrenByName[id] ?? [:]).values
            .compactMap { entries[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Looks up a name regardless of Unicode normalization: Finder often sends decomposed
    /// names ("a" + "¨") while ZIPs usually contain the precomposed form ("ä").
    public func lookup(_ name: String, in directoryID: UInt64) -> ArchiveEntry? {
        childrenByName[directoryID]?[Self.key(name)].flatMap { entries[$0] }
    }

    /// Normalized lookup key for a name; also used by ``EditableArchive``.
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    /// Looks up an entry by a path like `"folder/file.txt"`.
    public func lookup(path: String) -> ArchiveEntry? {
        var current = root
        for component in path.split(separator: "/") where !component.isEmpty {
            guard let next = lookup(String(component), in: current.id) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Building

    init(rootDate: Date) {
        entries[Self.rootID] = ArchiveEntry(
            id: Self.rootID, parentID: Self.rootID, name: "", kind: .directory, size: 0,
            modificationDate: rootDate, permissions: 0o755, symlinkTarget: nil,
            isEncrypted: false, archiveIndex: nil)
    }

    /// Normalizes a path from the archive into components. Returns `nil` if it's empty
    /// or would lead out of the volume (`..`).
    static func sanitize(_ path: String) -> [String]? {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": return nil
            default: components.append(String(part))
            }
        }
        return components.isEmpty ? nil : components
    }

    /// Inserts an entry, creating missing intermediate directories.
    /// If a path occurs twice, the later entry wins.
    mutating func insert(path components: [String], kind: ArchiveEntry.Kind, size: UInt64,
                         modificationDate: Date, permissions: UInt16, symlinkTarget: String?,
                         isEncrypted: Bool, archiveIndex: Int) {
        var parentID = Self.rootID
        for name in components.dropLast() {
            parentID = ensureDirectory(named: name, in: parentID, date: modificationDate)
        }
        let name = components.last!
        let existing = lookup(name, in: parentID)

        if kind == .directory, let existing, existing.isDirectory {
            // Explicit directory entry: take its metadata, keep the ID.
            entries[existing.id] = ArchiveEntry(
                id: existing.id, parentID: parentID, name: name, kind: .directory, size: 0,
                modificationDate: modificationDate, permissions: permissions,
                symlinkTarget: nil, isEncrypted: false, archiveIndex: archiveIndex)
            return
        }
        if let existing { remove(existing.id) }

        let id = makeID()
        entries[id] = ArchiveEntry(
            id: id, parentID: parentID, name: name, kind: kind, size: kind == .directory ? 0 : size,
            modificationDate: modificationDate, permissions: permissions,
            symlinkTarget: symlinkTarget, isEncrypted: isEncrypted, archiveIndex: archiveIndex)
        childrenByName[parentID, default: [:]][Self.key(name)] = id
    }

    private mutating func ensureDirectory(named name: String, in parentID: UInt64, date: Date) -> UInt64 {
        if let existing = lookup(name, in: parentID) {
            if existing.isDirectory { return existing.id }
            remove(existing.id)   // file and directory with the same name: the directory wins
        }
        let id = makeID()
        entries[id] = ArchiveEntry(
            id: id, parentID: parentID, name: name, kind: .directory, size: 0,
            modificationDate: date, permissions: 0o755, symlinkTarget: nil,
            isEncrypted: false, archiveIndex: nil)
        childrenByName[parentID, default: [:]][Self.key(name)] = id
        return id
    }

    private mutating func remove(_ id: UInt64) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        childrenByName[entry.parentID]?[Self.key(entry.name)] = nil
        for childID in (childrenByName.removeValue(forKey: id) ?? [:]).values {
            remove(childID)
        }
    }

    private mutating func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }
}
