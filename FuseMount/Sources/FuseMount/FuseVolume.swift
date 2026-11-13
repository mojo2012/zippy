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

/// Ein über FUSE-T gemountetes Archiv, nur lesbar.
///
/// ``serve(_:name:at:ready:)`` mountet und beantwortet Anfragen **im aufrufenden
/// Thread**, bis das Volume ausgehängt wird (z. B. Auswerfen im Finder). So erwartet
/// es FUSE-T: Mounten und Schleife im selben Thread, ein Volume pro Prozess. Mit
/// mehreren Volumes in Hintergrund-Threads eines Prozesses blieb das Aushängen hängen.
public final class FuseVolume: @unchecked Sendable {
    public let archive: ZipArchive
    public let name: String
    public let mountPoint: URL

    fileprivate let uid = getuid()
    fileprivate let gid = getgid()

    private init(archive: ZipArchive, name: String, mountPoint: URL) {
        self.archive = archive
        self.name = name
        self.mountPoint = mountPoint
    }

    /// Mountet und blockiert, bis das Volume ausgehängt ist.
    ///
    /// `ready` wird aus einem Hintergrund-Thread genau einmal aufgerufen: mit `nil`,
    /// sobald das Volume in der Mount-Tabelle steht, sonst mit dem Fehler.
    public static func serve(_ archive: ZipArchive, name: String, at mountPoint: URL, backend: FuseBackend,
                             ready: @escaping @Sendable ((any Error)?) -> Void) {
        guard zf_load(backend.libraryPath) == 0 else {
            return ready(FuseError.backendMissing(String(cString: zf_load_error())))
        }
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            return ready(error)
        }

        let volume = FuseVolume(archive: archive, name: name, mountPoint: mountPoint)
        var ops = makeOperations()
        // Kein eigenes "location": Der Servername muss auflösbar sein (FUSE-T trägt
        // "fuse-t" in /etc/hosts ein), sonst wird daraus "localhost". Darum stehen alle
        // Volumes in der Finder-Seitenleiste unter dem Server "fuse-t".
        let options = "volname=\(name.replacingOccurrences(of: ",", with: " ")),rdonly" + backend.extraOptions
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
        archive.close()
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

// MARK: - FUSE-Callbacks

private func currentVolume() -> FuseVolume {
    Unmanaged<FuseVolume>.fromOpaque(zf_private_data()!).takeUnretainedValue()
}

private func entry(_ path: UnsafePointer<CChar>?) -> ArchiveEntry? {
    guard let path else { return nil }
    return currentVolume().archive.index.lookup(path: String(cString: path))
}

private func timespec(_ date: Date) -> timespec {
    let seconds = date.timeIntervalSince1970.rounded(.down)
    return Darwin.timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1e9))
}

private func fill(_ st: UnsafeMutablePointer<stat>, with entry: ArchiveEntry, volume: FuseVolume) {
    st.pointee = stat()
    let type: mode_t = switch entry.kind {
    case .directory: S_IFDIR
    case .symlink: S_IFLNK
    case .file: S_IFREG
    }
    st.pointee.st_mode = type | mode_t(entry.permissions & 0o555)   // nur lesbar
    st.pointee.st_nlink = entry.isDirectory ? 2 : 1
    st.pointee.st_uid = volume.uid
    st.pointee.st_gid = volume.gid
    let size = entry.kind == .symlink ? UInt64(entry.symlinkTarget?.utf8.count ?? 0) : entry.size
    st.pointee.st_size = off_t(size)
    st.pointee.st_blksize = 4096
    st.pointee.st_blocks = blkcnt_t((size + 511) / 512)
    st.pointee.st_ino = ino_t(entry.id)
    let time = timespec(entry.modificationDate)
    st.pointee.st_mtimespec = time
    st.pointee.st_ctimespec = time
    st.pointee.st_atimespec = time
    st.pointee.st_birthtimespec = time
}

private func makeOperations() -> fuse_operations {
    var ops = fuse_operations()

    ops.getattr = { path, st in
        guard let st, let entry = entry(path) else { return -ENOENT }
        fill(st, with: entry, volume: currentVolume())
        return 0
    }

    ops.readdir = { path, buffer, filler, _, _ in
        guard let filler, let directory = entry(path) else { return -ENOENT }
        guard directory.isDirectory else { return -ENOTDIR }
        _ = filler(buffer, ".", nil, 0)
        _ = filler(buffer, "..", nil, 0)
        for child in currentVolume().archive.index.children(of: directory.id) {
            if filler(buffer, child.name, nil, 0) != 0 { break }
        }
        return 0
    }

    ops.open = { path, info in
        guard let info, let entry = entry(path) else { return -ENOENT }
        guard entry.kind == .file else { return -EISDIR }
        guard info.pointee.flags & O_ACCMODE == O_RDONLY else { return -EROFS }
        guard !entry.isEncrypted || currentVolume().archive.password != nil else { return -EACCES }
        info.pointee.fh = entry.id
        return 0
    }

    ops.read = { _, buffer, size, offset, info in
        guard let buffer, let info else { return -EIO }
        do {
            let data = try currentVolume().archive.read(info.pointee.fh, offset: UInt64(offset), length: size)
            data.copyBytes(to: UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self), count: data.count)
            return Int32(data.count)
        } catch {
            return -EIO
        }
    }

    ops.readlink = { path, buffer, size in
        guard let buffer, size > 0, let entry = entry(path) else { return -ENOENT }
        guard entry.kind == .symlink, let target = entry.symlinkTarget else { return -EINVAL }
        let bytes = Array(target.utf8.prefix(size - 1))
        for (i, byte) in bytes.enumerated() { buffer[i] = CChar(bitPattern: byte) }
        buffer[bytes.count] = 0
        return 0
    }

    ops.statfs = { _, st in
        guard let st else { return -EIO }
        let entries = currentVolume().archive.index.entries.values
        let total = entries.reduce(UInt64(0)) { $0 + $1.size }
        st.pointee = statvfs()
        st.pointee.f_bsize = 4096
        st.pointee.f_frsize = 4096
        st.pointee.f_blocks = fsblkcnt_t((total + 4095) / 4096)
        st.pointee.f_files = fsfilcnt_t(entries.count)
        st.pointee.f_namemax = 255
        return 0
    }

    return ops
}
