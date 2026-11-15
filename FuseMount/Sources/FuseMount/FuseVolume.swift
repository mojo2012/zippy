internal import CFuseT
import ArchiveCore
import Foundation
import os

let log = Logger(subsystem: "dev.zippy.Zippy", category: "fuse")

public enum FuseError: Error, LocalizedError {
    case backendMissing(String)
    case mountFailed(String)

    public var errorDescription: String? {
        switch self {
        case .backendMissing(let reason): String(localized: "The FUSE library can’t be loaded (\(reason)).", bundle: .module)
        case .mountFailed(let reason): String(localized: "Mounting failed: \(reason)", bundle: .module)
        }
    }
}

/// An archive mounted through FUSE. Writable unless ``EditableArchive/isReadOnly``;
/// ``EditableArchive`` collects the changes, which are saved after unmounting.
///
/// ``serve(_:name:at:backend:volumeIcon:ready:)`` mounts and answers requests **on the
/// calling thread** until the volume is unmounted (e.g. ejected in Finder). That's what
/// FUSE-T expects: mount and loop on the same thread, one volume per process. With
/// several volumes on background threads of one process, unmounting hung.
public final class FuseVolume: @unchecked Sendable {
    fileprivate let files: EditableArchive
    /// Read-only files Zippy adds to the root folder (path → file).
    fileprivate let virtualFiles: [String: VirtualFile]
    /// Whether the volume has a custom icon (Zippy's `.VolumeIcon.icns`).
    fileprivate let hasVolumeIcon: Bool

    fileprivate let uid = getuid()
    fileprivate let gid = getgid()

    private init(files: EditableArchive, volumeIcon: Data?, appleDouble: Bool) {
        self.files = files
        // If the archive itself already contains a file of that name, the archive's file wins.
        var virtual: [String: VirtualFile] = [:]
        if let volumeIcon, files.node(at: VolumeIcon.path) == nil {
            virtual[VolumeIcon.path] = VirtualFile(id: VolumeIcon.id, data: volumeIcon)
            if appleDouble, files.node(at: VolumeIcon.appleDoublePath) == nil {
                virtual[VolumeIcon.appleDoublePath] = VirtualFile(id: VolumeIcon.appleDoubleID,
                                                                  data: VolumeIcon.appleDoubleFinderInfo)
            }
        }
        virtualFiles = virtual
        hasVolumeIcon = virtual[VolumeIcon.path] != nil
    }

    /// Mounts and blocks until the volume is unmounted. Saving and closing `files`
    /// afterwards is up to the caller.
    ///
    /// `ready` is called exactly once from a background thread: with `nil` as soon as
    /// the volume is in the mount table, otherwise with the error.
    /// `volumeIcon` (an .icns file) becomes the volume's icon.
    public static func serve(_ files: EditableArchive, name: String, at mountPoint: URL, backend: FuseBackend,
                             volumeIcon: URL? = nil,
                             ready: @escaping @Sendable ((any Error)?) -> Void) {
        guard zf_load(backend.libraryPath) == 0 else {
            return ready(FuseError.backendMissing(String(cString: zf_load_error())))
        }
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            return ready(error)
        }

        let volume = FuseVolume(files: files, volumeIcon: volumeIcon.flatMap { try? Data(contentsOf: $0) },
                                appleDouble: backend.usesAppleDouble)
        var ops = makeOperations()
        // No custom "location": the server name must resolve (FUSE-T adds "fuse-t" to
        // /etc/hosts), otherwise it becomes "localhost". That's why all volumes appear
        // under the server "fuse-t" in the Finder sidebar.
        let options = "volname=\(name.replacingOccurrences(of: ",", with: " "))"
            + (files.isReadOnly ? ",rdonly" : "") + backend.extraOptions
        let userData = Unmanaged.passUnretained(volume).toOpaque()
        guard let rawHandle = zf_mount_new(mountPoint.path, options, &ops, userData) else {
            try? FileManager.default.removeItem(at: mountPoint)
            return ready(FuseError.mountFailed(String(localized: "FUSE-T refused the request", bundle: .module)))
        }

        // FUSE-T reports success before the actual mount, so check the mount table
        // while the loop below is already running.
        nonisolated(unsafe) let handle = rawHandle
        nonisolated(unsafe) var ejectWatcher: EjectWatcher?
        Thread.detachNewThread {
            if waitUntilMounted(mountPoint, timeout: 60) {
                log.info("Mounted \(name, privacy: .public) → \(mountPoint.path, privacy: .public)")
                if backend == .macFUSE {
                    // unmount(2) directly: macFUSE's fuse_unmount doesn't unmount in this situation.
                    let path = mountPoint.path
                    ejectWatcher = EjectWatcher(mountPoint: path) { Darwin.unmount(path, 0) }
                }
                ready(nil)
            } else {
                Darwin.unmount(mountPoint.path, MNT_FORCE)   // ends the loop
                ready(FuseError.mountFailed(String(localized: "the drive didn’t appear", bundle: .module)))
            }
        }

        let result = zf_mount_loop(handle)   // returns once unmounted
        log.info("Loop ended (\(result)): \(name, privacy: .public)")
        zf_mount_free(handle)
        ejectWatcher?.detachDevice()
        ejectWatcher = nil
        withExtendedLifetime(volume) {}
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Polls the mount table without touching the volume itself.
    private static func waitUntilMounted(_ mountPoint: URL, timeout: TimeInterval) -> Bool {
        // realpath rather than resolvingSymlinksInPath: the latter turns /private/tmp
        // back into /tmp, but the mount table lists /private/tmp.
        // Resolve only the parent: under /Volumes macFUSE creates the mount point only
        // while mounting, so realpath on the mount point itself fails before that.
        guard let resolved = realpath(mountPoint.deletingLastPathComponent().path, nil) else { return false }
        let target = String(cString: resolved) + "/" + mountPoint.lastPathComponent
        free(resolved)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Only look at the mount table, never the volume: any access by a process to
            // a FUSE-T (NFS) volume triggers the macOS "access network volumes" prompt
            // and blocks until it is answered.
            if mountedPaths().contains(target) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// All current mount points. Thread-safe, unlike `getmntinfo`, which uses a shared
    /// buffer and crashes when called concurrently.
    public static func mountedPaths() -> [String] {
        mountedFileSystems().map(\.mountPoint)
    }

    /// Mount point and device (e.g. "/dev/disk4" or "fuse-t:/Name") of every mount.
    public static func mountedFileSystems() -> [(mountPoint: String, device: String)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = [Darwin.statfs](repeating: Darwin.statfs(), count: Int(count) + 8)
        let filled = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
        }
        guard filled > 0 else { return [] }
        func string<T>(_ field: T) -> String {
            withUnsafeBytes(of: field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
        return buffer.prefix(Int(filled)).map { (string($0.f_mntonname), string($0.f_mntfromname)) }
    }
}

// MARK: - Volume icon

/// A read-only file in the root folder that doesn't come from the archive.
struct VirtualFile {
    /// Inode and file handle; doesn't collide with the archive's node IDs.
    let id: UInt64
    let data: Data
}

/// Custom volume icon, as on .dmg files: a hidden `.VolumeIcon.icns` in the root
/// folder plus the "has custom icon" flag in the root folder's Finder info.
/// FUSE-T's own `volicon` option makes the mount hang, hence done by hand.
///
/// The flag is served via `getxattr` (NFS with `namedattr`) or, where extended
/// attributes aren't passed through (FSKit), via the AppleDouble file `._.`, where
/// the kernel looks for the root folder's attributes.
private enum VolumeIcon {
    static let path = "/.VolumeIcon.icns"
    static let id: UInt64 = 0x7A49_636F_6E00_0001
    static let appleDoublePath = "/._."
    static let appleDoubleID: UInt64 = 0x7A49_636F_6E00_0002
    static let finderInfoName = "com.apple.FinderInfo"
    /// 32 bytes; frFlags (big-endian) at byte 8, kHasCustomIcon = 0x0400.
    static let finderInfo: [UInt8] = { var b = [UInt8](repeating: 0, count: 32); b[8] = 0x04; return b }()

    /// AppleDouble file with Finder info, laid out exactly as macOS writes it (4096 bytes):
    /// a header with two entries, the Finder info followed by an empty `ATTR` block for
    /// further attributes, and an empty resource fork at the end. The kernel ignores
    /// shorter variants.
    static let appleDoubleFinderInfo: Data = {
        var bytes = [UInt8](repeating: 0, count: 0x1000)
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
        }
        let finderInfoOffset = 0x32, resourceOffset = 0xEE2, resourceLength = 0x11E
        put(0x0005_1607, at: 0)                                     // magic
        put(0x0002_0000, at: 4)                                     // version
        bytes.replaceSubrange(8..<24, with: Array("Mac OS X        ".utf8))
        put16(2, at: 24)                                            // two entries
        put(9, at: 26); put(UInt32(finderInfoOffset), at: 30)       // Finder info …
        put(UInt32(resourceOffset - finderInfoOffset), at: 34)      // … including the ATTR block
        put(2, at: 38); put(UInt32(resourceOffset), at: 42); put(UInt32(resourceLength), at: 46)
        bytes.replaceSubrange(finderInfoOffset..<finderInfoOffset + 32, with: finderInfo)
        // ATTR header (after 2 bytes of padding): no further attributes
        let attr = finderInfoOffset + 32 + 2
        bytes.replaceSubrange(attr..<attr + 4, with: Array("ATTR".utf8))
        put(UInt32(resourceOffset), at: attr + 8)                   // total length
        put(UInt32(attr + 36), at: attr + 12)                       // data start
        // Empty resource fork: header, notice text, map
        for base in [resourceOffset, resourceOffset + 0x100] {
            put(0x100, at: base); put(0x100, at: base + 4); put(0, at: base + 8); put(0x1E, at: base + 12)
        }
        let blank = Array("This resource fork intentionally left blank   ".utf8)
        bytes.replaceSubrange(resourceOffset + 16..<resourceOffset + 16 + blank.count, with: blank)
        let map = resourceOffset + 0x100
        put16(0x1C, at: map + 24); put16(0x1E, at: map + 26); put16(0xFFFF, at: map + 28)
        return Data(bytes)
    }()

    static func isRoot(_ path: UnsafePointer<CChar>?) -> Bool {
        guard let path, currentVolume().hasVolumeIcon else { return false }
        return String(cString: path) == "/"
    }
}

private func virtualFile(_ path: UnsafePointer<CChar>?) -> VirtualFile? {
    guard let path else { return nil }
    let files = currentVolume().virtualFiles
    return files.isEmpty ? nil : files[String(cString: path)]
}

private func virtualFile(handle: UInt64) -> VirtualFile? {
    currentVolume().virtualFiles.values.first { $0.id == handle }
}

/// Copies `bytes` for getxattr/listxattr; without a buffer, only reports the length.
private func reply(_ bytes: [UInt8], into buffer: UnsafeMutablePointer<CChar>?, size: Int) -> Int32 {
    guard let buffer, size > 0 else { return Int32(bytes.count) }
    guard size >= bytes.count else { return -ERANGE }
    for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
    return Int32(bytes.count)
}

// MARK: - FUSE callbacks

private func currentVolume() -> FuseVolume {
    Unmanaged<FuseVolume>.fromOpaque(zf_private_data()!).takeUnretainedValue()
}

private func string(_ path: UnsafePointer<CChar>?) -> String {
    path.map { String(cString: $0) } ?? ""
}

private func node(_ path: UnsafePointer<CChar>?) -> EditableArchive.Node? {
    guard let path else { return nil }
    return currentVolume().files.node(at: String(cString: path))
}

/// Runs an operation and maps errors to negative errno values.
private func perform(_ body: () throws -> Void) -> Int32 {
    do {
        try body()
        return 0
    } catch let error as POSIXError {
        return -error.code.rawValue
    } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
        return -EACCES
    } catch {
        log.error("\(error.localizedDescription, privacy: .public)")
        return -EIO
    }
}

private func timespec(_ date: Date) -> timespec {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
}

private func date(_ time: Darwin.timespec) -> Date {
    Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
}

/// Fills the fields shared by archive nodes and virtual files; times stay zero.
private func fill(_ st: UnsafeMutablePointer<stat>, mode: mode_t, size: UInt64, inode: UInt64, volume: FuseVolume) {
    st.pointee = stat()
    st.pointee.st_mode = mode
    st.pointee.st_nlink = mode & S_IFMT == S_IFDIR ? 2 : 1
    st.pointee.st_uid = volume.uid
    st.pointee.st_gid = volume.gid
    st.pointee.st_size = off_t(size)
    st.pointee.st_blksize = 4096
    st.pointee.st_blocks = blkcnt_t((size + 511) / 512)
    st.pointee.st_ino = ino_t(inode)
}

private func fill(_ st: UnsafeMutablePointer<stat>, with node: EditableArchive.Node, volume: FuseVolume) {
    let type: mode_t = switch node.kind {
    case .directory: S_IFDIR
    case .symlink: S_IFLNK
    case .file: S_IFREG
    }
    let permissions = mode_t(node.permissions)
    // A symlink's size is the length of its target: FUSE-T via FSKit reads only that
    // many bytes, so with 0 the target would come back empty.
    let size = node.kind == .symlink ? UInt64(node.symlinkTarget?.utf8.count ?? 0) : node.size
    fill(st, mode: type | (volume.files.isReadOnly ? permissions & 0o555 : permissions),
         size: size, inode: node.id, volume: volume)
    let time = timespec(node.modificationDate)
    st.pointee.st_mtimespec = time
    st.pointee.st_ctimespec = time
    st.pointee.st_atimespec = time
    st.pointee.st_birthtimespec = time
}

private func fill(_ st: UnsafeMutablePointer<stat>, with file: VirtualFile, volume: FuseVolume) {
    fill(st, mode: S_IFREG | 0o444, size: UInt64(file.data.count), inode: file.id, volume: volume)
}

private func makeOperations() -> fuse_operations {
    var ops = fuse_operations()

    // MARK: Reading

    ops.getattr = { path, st in
        guard let st else { return -EIO }
        if let file = virtualFile(path) {
            fill(st, with: file, volume: currentVolume())
            return 0
        }
        guard let node = node(path) else { return -ENOENT }
        fill(st, with: node, volume: currentVolume())
        return 0
    }

    ops.fgetattr = { _, st, info in
        guard let st, let info else { return -EIO }
        let volume = currentVolume()
        if let file = virtualFile(handle: info.pointee.fh) {
            fill(st, with: file, volume: volume)
            return 0
        }
        // By handle, so that deleted files that are still open work too
        guard let node = volume.files.node(info.pointee.fh) else { return -ENOENT }
        fill(st, with: node, volume: volume)
        return 0
    }

    ops.readdir = { path, buffer, filler, _, _ in
        guard let filler, let directory = node(path) else { return -ENOENT }
        guard directory.isDirectory else { return -ENOTDIR }
        _ = filler(buffer, ".", nil, 0)
        _ = filler(buffer, "..", nil, 0)
        if string(path) == "/" {
            for virtualPath in currentVolume().virtualFiles.keys.sorted() {
                _ = filler(buffer, String(virtualPath.dropFirst()), nil, 0)
            }
        }
        for child in currentVolume().files.children(of: directory.id) {
            if filler(buffer, child.name, nil, 0) != 0 { break }
        }
        return 0
    }

    ops.open = { path, info in
        guard let info else { return -EIO }
        let volume = currentVolume()
        let writing = info.pointee.flags & O_ACCMODE != O_RDONLY
        if let file = virtualFile(path) {
            guard !writing else { return -EACCES }
            info.pointee.fh = file.id
            return 0
        }
        guard let node = node(path) else { return -ENOENT }
        guard node.kind == .file else { return -EISDIR }
        if writing && volume.files.isReadOnly { return -EROFS }
        guard !node.isEncrypted || volume.files.archive.password != nil else { return -EACCES }
        info.pointee.fh = node.id
        if info.pointee.flags & O_TRUNC != 0 {
            return perform { try volume.files.truncate(node.id, to: 0) }
        }
        return 0
    }

    ops.read = { _, buffer, size, offset, info in
        guard let buffer, let info, offset >= 0 else { return -EIO }
        let volume = currentVolume()
        if let data = virtualFile(handle: info.pointee.fh)?.data {
            let start = min(Int(offset), data.count), end = min(start + size, data.count)
            data.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self),
                           from: start..<end)
            return Int32(end - start)
        }
        do {
            let data = try volume.files.read(info.pointee.fh, offset: UInt64(offset), length: size)
            data.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: data.count)
            return Int32(data.count)
        } catch {
            return perform { throw error }
        }
    }

    ops.readlink = { path, buffer, size in
        guard let buffer, size > 0, let node = node(path) else { return -ENOENT }
        guard node.kind == .symlink, let target = node.symlinkTarget else { return -EINVAL }
        let bytes = Array(target.utf8.prefix(size - 1))
        for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return 0
    }

    ops.statfs = { _, st in
        guard let st else { return -EIO }
        let files = currentVolume().files
        let entries = files.archive.index.entries.values
        let used = entries.reduce(UInt64(0)) { $0 + $1.size }
        // Free space: that of the temporary directory, where new files land first.
        // Without it, Finder refuses to copy anything onto the volume.
        var free: UInt64 = 0
        if !files.isReadOnly,
           let bytes = try? FileManager.default.attributesOfFileSystem(forPath: NSTemporaryDirectory())[.systemFreeSize]
               as? NSNumber {
            free = bytes.uint64Value / 4096
        }
        st.pointee = statvfs()
        st.pointee.f_bsize = 4096
        st.pointee.f_frsize = 4096
        st.pointee.f_blocks = fsblkcnt_t((used + 4095) / 4096 + free)
        st.pointee.f_bfree = fsblkcnt_t(free)
        st.pointee.f_bavail = fsblkcnt_t(free)
        st.pointee.f_files = fsfilcnt_t(entries.count) + (files.isReadOnly ? 0 : 1_000_000)
        st.pointee.f_ffree = files.isReadOnly ? 0 : 1_000_000
        st.pointee.f_favail = st.pointee.f_ffree
        st.pointee.f_namemax = 255
        return 0
    }

    // MARK: Writing

    ops.create = { path, mode, info in
        guard let info else { return -EIO }
        return perform {
            let node = try currentVolume().files.createFile(at: string(path), permissions: UInt16(mode & 0o777))
            info.pointee.fh = node.id
        }
    }

    ops.mknod = { path, mode, _ in
        guard mode & S_IFMT == S_IFREG else { return -EPERM }
        return perform { try currentVolume().files.createFile(at: string(path), permissions: UInt16(mode & 0o777)) }
    }

    ops.write = { _, buffer, size, offset, info in
        guard let buffer, let info, offset >= 0 else { return -EIO }
        if virtualFile(handle: info.pointee.fh) != nil { return -EACCES }
        var written = 0
        let status = perform {
            written = try currentVolume().files.write(info.pointee.fh, bytes: UnsafeRawBufferPointer(start: buffer, count: size),
                                                      at: UInt64(offset))
        }
        return status == 0 ? Int32(written) : status
    }

    ops.truncate = { path, size in
        guard let node = node(path) else { return -ENOENT }
        return perform { try currentVolume().files.truncate(node.id, to: UInt64(max(0, size))) }
    }

    ops.ftruncate = { _, size, info in
        guard let info else { return -EIO }
        return perform { try currentVolume().files.truncate(info.pointee.fh, to: UInt64(max(0, size))) }
    }

    ops.mkdir = { path, mode in
        perform { try currentVolume().files.createDirectory(at: string(path), permissions: UInt16(mode & 0o777)) }
    }

    ops.unlink = { path in
        if virtualFile(path) != nil { return -EACCES }
        return perform { try currentVolume().files.removeFile(at: string(path)) }
    }

    ops.rmdir = { path in
        perform { try currentVolume().files.removeDirectory(at: string(path)) }
    }

    ops.rename = { from, to in
        if virtualFile(from) != nil || virtualFile(to) != nil { return -EACCES }
        return perform { try currentVolume().files.move(from: string(from), to: string(to)) }
    }

    ops.symlink = { target, path in
        perform { try currentVolume().files.createSymlink(at: string(path), target: string(target)) }
    }

    ops.chmod = { path, mode in
        if virtualFile(path) != nil { return 0 }
        guard let node = node(path) else { return -ENOENT }
        return perform { try currentVolume().files.setPermissions(node.id, to: UInt16(mode & 0o777)) }
    }

    // Archives don't store owners: accept and ignore, otherwise copying fails
    ops.chown = { path, _, _ in
        virtualFile(path) != nil || node(path) != nil ? 0 : -ENOENT
    }

    ops.utimens = { path, times in
        if virtualFile(path) != nil { return 0 }
        guard let node = node(path) else { return -ENOENT }
        let modification = times.map { $0[1] } ?? Darwin.timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))
        if modification.tv_nsec == Int(UTIME_OMIT) { return 0 }
        let newDate = modification.tv_nsec == Int(UTIME_NOW) ? Date() : date(modification)
        return perform { try currentVolume().files.setModificationDate(node.id, to: newDate) }
    }

    ops.flush = { _, _ in 0 }
    ops.release = { _, _ in 0 }
    ops.fsync = { _, _, _ in 0 }

    // MARK: Extended attributes
    // Kept in memory only, since ZIP can't store them. Finder sets some while copying
    // (e.g. com.apple.quarantine) and aborts if that fails.

    ops.listxattr = { path, buffer, size in
        guard let node = node(path) else { return virtualFile(path) != nil ? 0 : -ENOENT }
        var names = currentVolume().files.extendedAttributeNames(of: node.id)
        if VolumeIcon.isRoot(path), !names.contains(VolumeIcon.finderInfoName) { names.append(VolumeIcon.finderInfoName) }
        return reply(names.flatMap { Array($0.utf8) + [0] }, into: buffer, size: size)
    }

    ops.getxattr = { path, name, buffer, size, _ in
        guard let name else { return -EINVAL }
        let attribute = String(cString: name)
        if VolumeIcon.isRoot(path), attribute == VolumeIcon.finderInfoName {
            return reply(VolumeIcon.finderInfo, into: buffer, size: size)
        }
        guard let node = node(path),
              let value = currentVolume().files.extendedAttribute(attribute, of: node.id) else { return -ENOATTR }
        return reply(Array(value), into: buffer, size: size)
    }

    ops.setxattr = { path, name, value, size, _, _ in
        guard let name else { return -EINVAL }
        if virtualFile(path) != nil || VolumeIcon.isRoot(path) && String(cString: name) == VolumeIcon.finderInfoName {
            return 0   // the custom-icon flag stays ours
        }
        guard let node = node(path) else { return -ENOENT }
        let data = value.map { Data(bytes: $0, count: size) } ?? Data()
        return perform { try currentVolume().files.setExtendedAttribute(String(cString: name), to: data, of: node.id) }
    }

    ops.removexattr = { path, name in
        guard let name, let node = node(path) else { return -ENOENT }
        let attribute = String(cString: name)
        guard currentVolume().files.extendedAttribute(attribute, of: node.id) != nil else { return -ENOATTR }
        return perform { try currentVolume().files.setExtendedAttribute(attribute, to: nil, of: node.id) }
    }

    return ops
}
