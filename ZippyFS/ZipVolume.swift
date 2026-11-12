import FSKit

/// Eintrag im Volume. Für den Prototyp: nur Wurzelordner und eine Info-Datei.
final class ZipItem: FSItem {
    let id: FSItem.Identifier
    let name: FSFileName
    let isDirectory: Bool
    let contents: Data

    init(id: FSItem.Identifier, name: String, isDirectory: Bool, contents: Data = Data()) {
        self.id = id
        self.name = FSFileName(string: name)
        self.isDirectory = isDirectory
        self.contents = contents
    }
}

/// Nur lesendes Volume. Alles, was schreibt, antwortet mit EROFS.
final class ZipVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {

    private let root = ZipItem(id: .rootDirectory, name: "/", isDirectory: true)
    private let infoFile: ZipItem
    private let mountTime = timespec(tv_sec: Int(Date().timeIntervalSince1970), tv_nsec: 0)

    init(info: String) {
        infoFile = ZipItem(id: FSItem.Identifier(rawValue: 3)!, name: "Zippy-Test.txt",
                           isDirectory: false, contents: Data(info.utf8))
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: "Zippy"))
    }

    // MARK: Eigenschaften

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supports64BitObjectIDs = true
        caps.supportsPersistentObjectIDs = true
        caps.doesNotSupportSettingFilePermissions = true
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "zippy")
        stats.blockSize = 4096
        stats.ioSize = 4096
        stats.totalBlocks = 1
        stats.usedBlocks = 1
        stats.totalBytes = UInt64(infoFile.contents.count)
        stats.usedBytes = UInt64(infoFile.contents.count)
        stats.totalFiles = 2
        return stats
    }

    // MARK: Lebenszyklus

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        reply(root, nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: Lesen

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let item = item as? ZipItem else { return reply(nil, POSIXError(.ENOENT)) }
        reply(attributes(of: item), nil)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard directory === root, name.data == infoFile.name.data else {
            return reply(nil, nil, POSIXError(.ENOENT))
        }
        reply(infoFile, infoFile.name, nil)
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard directory === root else { return reply(verifier, POSIXError(.ENOTDIR)) }
        let entries: [(FSFileName, ZipItem)] = [
            (FSFileName(string: "."), root),
            (FSFileName(string: ".."), root),
            (infoFile.name, infoFile),
        ]
        for index in Int(cookie.rawValue)..<entries.count {
            let (name, item) = entries[index]
            let packed = packer.packEntry(name: name,
                                          itemType: item.isDirectory ? .directory : .file,
                                          itemID: item.id,
                                          nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                          attributes: attributes == nil ? nil : self.attributes(of: item))
            if !packed { break }
        }
        reply(FSDirectoryVerifier(rawValue: 1), nil)
    }

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let item = item as? ZipItem, !item.isDirectory else { return reply(0, POSIXError(.EISDIR)) }
        let data = item.contents
        guard offset < data.count else { return reply(0, nil) }
        let end = min(data.count, Int(offset) + min(length, buffer.length))
        let slice = data[Int(offset)..<end]
        _ = buffer.withUnsafeMutableBytes { dest in
            slice.copyBytes(to: dest)
        }
        reply(slice.count, nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.EINVAL))
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    // MARK: Schreiben (nicht unterstützt)

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

    // MARK: Hilfen

    private func attributes(of item: ZipItem) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = item.isDirectory ? .directory : .file
        attrs.mode = item.isDirectory ? UInt32(S_IFDIR | 0o555) : UInt32(S_IFREG | 0o444)
        attrs.linkCount = item.isDirectory ? 2 : 1
        attrs.uid = 99   // "unknown": Finder zeigt den aktuellen Nutzer
        attrs.gid = 99
        attrs.size = UInt64(item.contents.count)
        attrs.allocSize = UInt64(item.contents.count)
        attrs.fileID = item.id
        attrs.parentID = item.isDirectory ? .parentOfRoot : .rootDirectory
        attrs.modifyTime = mountTime
        attrs.changeTime = mountTime
        attrs.accessTime = mountTime
        attrs.birthTime = mountTime
        return attrs
    }
}
