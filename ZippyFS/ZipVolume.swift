import ArchiveCore
import FSKit

/// An archive entry as an FSKit item. There is exactly one `ZipItem` per entry,
/// so FSKit always sees the same file as the same object.
final class ZipItem: FSItem {
    let entry: ArchiveEntry
    init(entry: ArchiveEntry) { self.entry = entry }
}

/// Read-only volume backed by an ``Archive``. Every write operation fails with EROFS.
final class ZipVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations, @unchecked Sendable {

    let archive: Archive
    private let lock = NSLock()
    private var items: [UInt64: ZipItem] = [:]

    init(archive: Archive, name: String) {
        self.archive = archive
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: name))
    }

    private func item(for entry: ArchiveEntry) -> ZipItem {
        lock.withLock {
            if let item = items[entry.id] { return item }
            let item = ZipItem(entry: entry)
            items[entry.id] = item
            return item
        }
    }

    // MARK: Properties

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supports64BitObjectIDs = true
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = true
        caps.doesNotSupportSettingFilePermissions = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let entries = archive.index.entries.values
        let total = entries.reduce(UInt64(0)) { $0 + $1.size }
        let stats = FSStatFSResult(fileSystemTypeName: "zippy")
        stats.blockSize = 4096
        stats.ioSize = 64 * 1024
        stats.totalBlocks = (total + 4095) / 4096
        stats.usedBlocks = stats.totalBlocks
        stats.totalBytes = total
        stats.usedBytes = total
        stats.totalFiles = UInt64(entries.count)
        return stats
    }

    // MARK: Lifecycle

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(item(for: archive.index.root), nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        archive.close()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: Reading

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? ZipItem else { return reply(nil, POSIXError(.ENOENT)) }
        reply(Self.attributes(of: item.entry), nil)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let directory = directory as? ZipItem, directory.entry.isDirectory else {
            return reply(nil, nil, POSIXError(.ENOTDIR))
        }
        let string = name.string ?? String(decoding: name.data, as: UTF8.self)
        guard let entry = archive.index.lookup(string, in: directory.entry.id) else {
            return reply(nil, nil, POSIXError(.ENOENT))
        }
        reply(item(for: entry), FSFileName(string: entry.name), nil)
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let directory = directory as? ZipItem, directory.entry.isDirectory else {
            return reply(verifier, POSIXError(.ENOTDIR))
        }
        let index = archive.index
        let parent = index.entry(directory.entry.parentID) ?? directory.entry
        // Cookie = position in this list. The archive never changes, so the verifier
        // is constant.
        let entries: [(String, ArchiveEntry)] =
            [(".", directory.entry), ("..", parent)] + index.children(of: directory.entry.id).map { ($0.name, $0) }

        for position in Int(cookie.rawValue)..<entries.count {
            let (name, entry) = entries[position]
            let packed = packer.packEntry(
                name: FSFileName(string: name),
                itemType: Self.itemType(entry.kind),
                itemID: FSItem.Identifier(rawValue: entry.id) ?? .invalid,
                nextCookie: FSDirectoryCookie(rawValue: UInt64(position + 1)),
                attributes: attributes == nil ? nil : Self.attributes(of: entry))
            if !packed { break }
        }
        reply(FSDirectoryVerifier(rawValue: 1), nil)
    }

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? ZipItem else { return reply(0, POSIXError(.ENOENT)) }
        guard item.entry.kind == .file else { return reply(0, POSIXError(.EISDIR)) }
        guard !item.entry.isEncrypted || archive.password != nil else { return reply(0, POSIXError(.EACCES)) }
        do {
            let data = try archive.read(item.entry.id, offset: UInt64(max(0, offset)), length: min(length, buffer.length))
            _ = buffer.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            reply(data.count, nil)
        } catch {
            reply(0, POSIXError(.EIO))
        }
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard let item = item as? ZipItem, item.entry.kind == .symlink, let target = item.entry.symlinkTarget else {
            return reply(nil, POSIXError(.EINVAL))
        }
        reply(FSFileName(string: target), nil)
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        if let item = item as? ZipItem {
            lock.withLock { items[item.entry.id] = nil }
        }
        reply(nil)
    }

    // MARK: Writing (not supported)

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.EROFS))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, POSIXError(.EROFS))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, POSIXError(.EROFS))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.EROFS))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(POSIXError(.EROFS))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.EROFS))
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        reply(0, POSIXError(.EROFS))
    }

    // MARK: Helpers

    private static func itemType(_ kind: ArchiveEntry.Kind) -> FSItem.ItemType {
        switch kind {
        case .directory: .directory
        case .symlink: .symlink
        case .file: .file
        }
    }

    private static func attributes(of entry: ArchiveEntry) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = itemType(entry.kind)
        let typeBits: mode_t = switch entry.kind {
        case .directory: S_IFDIR
        case .symlink: S_IFLNK
        case .file: S_IFREG
        }
        attrs.mode = UInt32(typeBits) | UInt32(entry.permissions & 0o555)   // read-only
        attrs.linkCount = entry.isDirectory ? 2 : 1
        attrs.uid = 99   // "unknown": macOS shows the logged-in user as the owner
        attrs.gid = 99
        let size = entry.kind == .symlink ? UInt64(entry.symlinkTarget?.utf8.count ?? 0) : entry.size
        attrs.size = size
        attrs.allocSize = (size + 4095) / 4096 * 4096
        attrs.fileID = FSItem.Identifier(rawValue: entry.id) ?? .invalid
        attrs.parentID = entry.id == ArchiveIndex.rootID
            ? .parentOfRoot
            : FSItem.Identifier(rawValue: entry.parentID) ?? .invalid
        let seconds = entry.modificationDate.timeIntervalSince1970
        let time = timespec(tv_sec: Int(seconds), tv_nsec: Int((seconds - seconds.rounded(.down)) * 1e9))
        attrs.modifyTime = time
        attrs.changeTime = time
        attrs.accessTime = time
        attrs.birthTime = time
        return attrs
    }
}
