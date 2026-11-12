import Foundation

/// Ordnerbaum eines Archivs, einmal beim Öffnen aufgebaut.
public struct ArchiveIndex: Sendable {
    public static let rootID: UInt64 = 2

    public private(set) var entries: [UInt64: ArchiveEntry] = [:]
    private var childrenByName: [UInt64: [String: UInt64]] = [:]
    private var nextID: UInt64 = 3

    public var root: ArchiveEntry { entries[Self.rootID]! }

    public func entry(_ id: UInt64) -> ArchiveEntry? { entries[id] }

    /// Kinder eines Ordners, nach Namen sortiert.
    public func children(of id: UInt64) -> [ArchiveEntry] {
        (childrenByName[id] ?? [:]).values
            .compactMap { entries[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func lookup(_ name: String, in directoryID: UInt64) -> ArchiveEntry? {
        childrenByName[directoryID]?[name].flatMap { entries[$0] }
    }

    /// Sucht einen Eintrag über einen Pfad wie `"ordner/datei.txt"`.
    public func lookup(path: String) -> ArchiveEntry? {
        var current = root
        for component in path.split(separator: "/") where !component.isEmpty {
            guard let next = lookup(String(component), in: current.id) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Aufbau

    init(rootDate: Date) {
        entries[Self.rootID] = ArchiveEntry(
            id: Self.rootID, parentID: Self.rootID, name: "", kind: .directory, size: 0,
            modificationDate: rootDate, permissions: 0o755, symlinkTarget: nil,
            isEncrypted: false, archiveIndex: nil)
    }

    /// Bereinigt einen Pfad aus dem Archiv. Gibt `nil` zurück, wenn er aus dem
    /// Volume hinausführen würde (`..`).
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

    /// Fügt einen Eintrag ein. Fehlende Zwischenordner werden angelegt.
    /// Kommt ein Pfad doppelt vor, gewinnt der spätere Eintrag.
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
            // Expliziter Ordner-Eintrag: Metadaten übernehmen, ID behalten.
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
        childrenByName[parentID, default: [:]][name] = id
    }

    private mutating func ensureDirectory(named name: String, in parentID: UInt64, date: Date) -> UInt64 {
        if let existing = lookup(name, in: parentID) {
            if existing.isDirectory { return existing.id }
            remove(existing.id)   // Datei und Ordner mit gleichem Namen: Ordner gewinnt
        }
        let id = makeID()
        entries[id] = ArchiveEntry(
            id: id, parentID: parentID, name: name, kind: .directory, size: 0,
            modificationDate: date, permissions: 0o755, symlinkTarget: nil,
            isEncrypted: false, archiveIndex: nil)
        childrenByName[parentID, default: [:]][name] = id
        return id
    }

    private mutating func remove(_ id: UInt64) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        childrenByName[entry.parentID]?[entry.name] = nil
        for childID in (childrenByName.removeValue(forKey: id) ?? [:]).values {
            remove(childID)
        }
    }

    private mutating func makeID() -> UInt64 {
        defer { nextID += 1 }
        return nextID
    }
}
