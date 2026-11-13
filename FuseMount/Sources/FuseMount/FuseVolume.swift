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
        case .backendMissing(let reason): "FUSE-Bibliothek nicht ladbar (\(reason))."
        case .mountFailed(let reason): "Mounten fehlgeschlagen: \(reason)"
        }
    }
}

/// Ein über FUSE-T gemountetes Archiv. Beschreibbar, außer ``EditableArchive/isReadOnly``;
/// Änderungen sammelt ``EditableArchive``, gespeichert wird nach dem Aushängen.
///
/// ``serve(_:name:at:ready:)`` mountet und beantwortet Anfragen **im aufrufenden
/// Thread**, bis das Volume ausgehängt wird (z. B. Auswerfen im Finder). So erwartet
/// es FUSE-T: Mounten und Schleife im selben Thread, ein Volume pro Prozess. Mit
/// mehreren Volumes in Hintergrund-Threads eines Prozesses blieb das Aushängen hängen.
public final class FuseVolume: @unchecked Sendable {
    public let files: EditableArchive
    public let name: String
    public let mountPoint: URL
    /// Nur lesbare Dateien, die Zippy zusätzlich in den Wurzelordner legt (Pfad → Datei).
    fileprivate let virtualFiles: [String: VirtualFile]
    /// Hat das Volume ein eigenes Symbol (`.VolumeIcon.icns` von Zippy)?
    fileprivate let hasVolumeIcon: Bool

    fileprivate let uid = getuid()
    fileprivate let gid = getgid()

    private init(files: EditableArchive, name: String, mountPoint: URL, volumeIcon: Data?, appleDouble: Bool) {
        self.files = files
        self.name = name
        self.mountPoint = mountPoint
        // Liegt im Archiv selbst schon eine Datei dieses Namens, gewinnt die aus dem Archiv.
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

    /// Mountet und blockiert, bis das Volume ausgehängt ist. Speichern und Schließen
    /// von `files` ist danach Sache des Aufrufers.
    ///
    /// `ready` wird aus einem Hintergrund-Thread genau einmal aufgerufen: mit `nil`,
    /// sobald das Volume in der Mount-Tabelle steht, sonst mit dem Fehler.
    /// `volumeIcon` (eine .icns-Datei) wird zum Symbol des Volumes.
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

        let volume = FuseVolume(files: files, name: name, mountPoint: mountPoint,
                                volumeIcon: volumeIcon.flatMap { try? Data(contentsOf: $0) },
                                appleDouble: backend.usesAppleDouble)
        var ops = makeOperations()
        // Kein eigenes "location": Der Servername muss auflösbar sein (FUSE-T trägt
        // "fuse-t" in /etc/hosts ein), sonst wird daraus "localhost". Darum stehen alle
        // Volumes in der Finder-Seitenleiste unter dem Server "fuse-t".
        let options = "volname=\(name.replacingOccurrences(of: ",", with: " "))"
            + (files.isReadOnly ? ",rdonly" : "") + backend.extraOptions
        let userData = Unmanaged.passUnretained(volume).toOpaque()
        guard let rawHandle = zf_mount_new(mountPoint.path, options, &ops, userData) else {
            try? FileManager.default.removeItem(at: mountPoint)
            return ready(FuseError.mountFailed("FUSE-T hat den Auftrag abgelehnt"))
        }

        // FUSE-T meldet Erfolg schon vor dem eigentlichen Mount. Darum nachsehen,
        // während die Schleife unten schon läuft.
        nonisolated(unsafe) let handle = rawHandle
        nonisolated(unsafe) var ejectWatcher: EjectWatcher?
        Thread.detachNewThread {
            if waitUntilMounted(mountPoint, timeout: 60) {
                log.info("gemountet: \(name, privacy: .public) → \(mountPoint.path, privacy: .public)")
                if backend == .macFUSE {
                    // Direkt unmount(2): macFUSEs fuse_unmount hängt in dieser Lage nicht aus.
                    let path = mountPoint.path
                    ejectWatcher = EjectWatcher(mountPoint: path) { Darwin.unmount(path, 0) }
                }
                ready(nil)
            } else {
                Darwin.unmount(mountPoint.path, MNT_FORCE)   // beendet die Schleife
                ready(FuseError.mountFailed("Volume ist nicht erschienen"))
            }
        }

        let result = zf_mount_loop(handle)   // kehrt zurück, sobald ausgehängt wurde
        log.info("Schleife beendet (\(result)): \(name, privacy: .public)")
        zf_mount_free(handle)
        ejectWatcher?.detachDevice()
        ejectWatcher = nil
        withExtendedLifetime(volume) {}
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Prüft die Mount-Tabelle, ohne das Volume selbst anzufassen.
    private static func waitUntilMounted(_ mountPoint: URL, timeout: TimeInterval) -> Bool {
        // realpath statt resolvingSymlinksInPath: Letzteres macht aus /private/tmp
        // wieder /tmp, die Mount-Tabelle führt aber /private/tmp.
        // Nur den Elternordner auflösen: Unter /Volumes legt macFUSE den Mountpunkt
        // erst beim Mounten an, realpath auf den Mountpunkt selbst scheitert vorher.
        guard let resolved = realpath(mountPoint.deletingLastPathComponent().path, nil) else { return false }
        let target = String(cString: resolved) + "/" + mountPoint.lastPathComponent
        free(resolved)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Nur die Mount-Tabelle ansehen, nicht das Volume selbst: Jeder Zugriff eines
            // Prozesses auf ein FUSE-T-Volume (NFS) löst die macOS-Abfrage
            // „Zugriff auf Netzwerk-Volumes“ aus und blockiert bis zur Antwort.
            if mountedPaths().contains(target) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Alle aktuellen Mountpunkte. Thread-sicher (anders als `getmntinfo`,
    /// das einen gemeinsamen Puffer nutzt und bei parallelem Aufruf abstürzt).
    public static func mountedPaths() -> [String] {
        mountedFileSystems().map(\.mountPoint)
    }

    /// Mountpunkt und Gerät (z. B. "/dev/disk4" oder "fuse-t:/Name") aller Mounts.
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

// MARK: - Volume-Symbol

/// Eine nur lesbare Datei im Wurzelordner, die nicht aus dem Archiv kommt.
struct VirtualFile {
    /// Inode und Datei-Handle; kollidiert nicht mit Knoten-IDs des Archivs.
    let id: UInt64
    let data: Data
}

/// Eigenes Volume-Symbol wie bei .dmg-Dateien: eine versteckte `.VolumeIcon.icns`
/// im Wurzelordner, dazu im Finder-Info des Wurzelordners das Flag "eigenes Symbol".
/// FUSE-Ts eigene Option `volicon` lässt den Mount hängen, darum von Hand.
///
/// Das Flag kommt über `getxattr` (NFS mit `namedattr`) oder, wo erweiterte Attribute
/// nicht durchgereicht werden (FSKit), über die AppleDouble-Datei `._.`: Darin sucht
/// der Kernel die Attribute des Wurzelordners.
private enum VolumeIcon {
    static let path = "/.VolumeIcon.icns"
    static let id: UInt64 = 0x7A49_636F_6E00_0001
    static let appleDoublePath = "/._."
    static let appleDoubleID: UInt64 = 0x7A49_636F_6E00_0002
    static let finderInfoName = "com.apple.FinderInfo"
    /// 32 Byte; frFlags (Big Endian) ab Byte 8, kHasCustomIcon = 0x0400.
    static let finderInfo: [UInt8] = { var b = [UInt8](repeating: 0, count: 32); b[8] = 0x04; return b }()

    /// AppleDouble-Datei mit Finder-Info, so wie macOS sie selbst schreibt (4096 Byte):
    /// Kopf mit zwei Einträgen, Finder-Info samt leerem `ATTR`-Block für weitere
    /// Attribute, am Ende ein leerer Resource-Fork. Kürzere Varianten liest der Kernel nicht.
    static let appleDoubleFinderInfo: Data = {
        var bytes = [UInt8](repeating: 0, count: 0x1000)
        func put(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
        }
        let finderInfoOffset = 0x32, resourceOffset = 0xEE2, resourceLength = 0x11E
        put(0x0005_1607, at: 0)                                     // Magic
        put(0x0002_0000, at: 4)                                     // Version
        bytes.replaceSubrange(8..<24, with: Array("Mac OS X        ".utf8))
        put16(2, at: 24)                                            // zwei Einträge
        put(9, at: 26); put(UInt32(finderInfoOffset), at: 30)       // Finder-Info …
        put(UInt32(resourceOffset - finderInfoOffset), at: 34)      // … samt ATTR-Block
        put(2, at: 38); put(UInt32(resourceOffset), at: 42); put(UInt32(resourceLength), at: 46)
        bytes.replaceSubrange(finderInfoOffset..<finderInfoOffset + 32, with: finderInfo)
        // ATTR-Kopf (nach 2 Byte Ausrichtung): keine weiteren Attribute
        let attr = finderInfoOffset + 32 + 2
        bytes.replaceSubrange(attr..<attr + 4, with: Array("ATTR".utf8))
        put(UInt32(resourceOffset), at: attr + 8)                   // Gesamtlänge
        put(UInt32(attr + 36), at: attr + 12)                       // Daten-Anfang
        // Leerer Resource-Fork: Kopf, Hinweistext, Map
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

/// Kopiert `bytes` für getxattr/listxattr: ohne Puffer nur die Länge melden.
private func reply(_ bytes: [UInt8], into buffer: UnsafeMutablePointer<CChar>?, size: Int) -> Int32 {
    guard let buffer, size > 0 else { return Int32(bytes.count) }
    guard size >= bytes.count else { return -ERANGE }
    for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
    return Int32(bytes.count)
}

// MARK: - FUSE-Callbacks

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

/// Führt eine Änderung aus und übersetzt Fehler in negative errno-Werte.
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

private func fill(_ st: UnsafeMutablePointer<stat>, with node: EditableArchive.Node, volume: FuseVolume) {
    st.pointee = stat()
    let type: mode_t = switch node.kind {
    case .directory: S_IFDIR
    case .symlink: S_IFLNK
    case .file: S_IFREG
    }
    let permissions = mode_t(node.permissions)
    st.pointee.st_mode = type | (volume.files.isReadOnly ? permissions & 0o555 : permissions)
    st.pointee.st_nlink = node.isDirectory ? 2 : 1
    st.pointee.st_uid = volume.uid
    st.pointee.st_gid = volume.gid
    st.pointee.st_size = off_t(node.size)
    st.pointee.st_blksize = 4096
    st.pointee.st_blocks = blkcnt_t((node.size + 511) / 512)
    st.pointee.st_ino = ino_t(node.id)
    let time = timespec(node.modificationDate)
    st.pointee.st_mtimespec = time
    st.pointee.st_ctimespec = time
    st.pointee.st_atimespec = time
    st.pointee.st_birthtimespec = time
}

private func fill(_ st: UnsafeMutablePointer<stat>, with file: VirtualFile, volume: FuseVolume) {
    let size = UInt64(file.data.count)
    st.pointee = stat()
    st.pointee.st_mode = S_IFREG | 0o444
    st.pointee.st_nlink = 1
    st.pointee.st_uid = volume.uid
    st.pointee.st_gid = volume.gid
    st.pointee.st_size = off_t(size)
    st.pointee.st_blksize = 4096
    st.pointee.st_blocks = blkcnt_t((size + 511) / 512)
    st.pointee.st_ino = ino_t(file.id)
}

private func makeOperations() -> fuse_operations {
    var ops = fuse_operations()

    // MARK: Lesen

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

    ops.fgetattr = { path, st, info in
        guard let st, let info else { return -EIO }
        let volume = currentVolume()
        if let file = virtualFile(handle: info.pointee.fh) {
            fill(st, with: file, volume: volume)
            return 0
        }
        // Über das Handle, damit auch gelöschte, noch offene Dateien gehen
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
        if let icon = virtualFile(handle: info.pointee.fh)?.data {
            let start = min(Int(offset), icon.count), end = min(start + size, icon.count)
            icon.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self),
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
        // Freier Platz: der des Arbeitsordners (dort landen neue Dateien zuerst).
        // Ohne Angabe lehnt der Finder das Kopieren ab.
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

    // MARK: Schreiben

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

    // Besitzer gibt es im ZIP nicht: annehmen und ignorieren, sonst scheitert das Kopieren
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

    // MARK: Erweiterte Attribute
    // Nur im Speicher: ZIP kennt sie nicht. Der Finder setzt beim Kopieren welche
    // (z. B. com.apple.quarantine) und bricht ab, wenn das scheitert.

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
            return 0   // Symbol-Markierung bleibt unsere
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
