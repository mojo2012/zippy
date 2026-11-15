import Foundation

/// Which FUSE implementation provides the volume. All of them speak libfuse 2,
/// so the code on top is the same.
public enum FuseBackend: String, CaseIterable, Sendable {
    /// FUSE-T over NFS, no system extension. Volumes show up in the Finder sidebar
    /// as shares of the server "fuse-t".
    case fuseT = "fuse-t"
    /// macFUSE via FSKit (`backend=fskit`): local volumes. Experimental, see
    /// ``choose(setting:)``.
    case macFUSE = "macfuse"
    /// FUSE-T via FSKit (`backend=fskit`, macOS 26 or later, needs /Applications/fuse-t.app
    /// with its extension turned on). Local volumes under /Volumes/Zippy: shown in the
    /// Finder sidebar and on the desktop, ejectable, several at once.
    case fuseTFSKit = "fuse-t-fskit"

    public var displayName: String {
        switch self {
        case .fuseT, .fuseTFSKit: "FUSE-T"
        case .macFUSE: "macFUSE"
        }
    }

    public var downloadURL: URL {
        switch self {
        case .fuseT, .fuseTFSKit: URL(string: "https://www.fuse-t.org")!
        case .macFUSE: URL(string: "https://macfuse.github.io")!
        }
    }

    var libraryPath: String {
        switch self {
        case .fuseT, .fuseTFSKit: "/usr/local/lib/libfuse-t.dylib"
        case .macFUSE: "/usr/local/lib/libfuse.2.dylib"
        }
    }

    /// Additional mount options, each with a leading comma.
    var extraOptions: String {
        switch self {
        case .fuseT: ",namedattr"   // extended attributes (Finder info for the volume icon)
        case .macFUSE, .fuseTFSKit: ",backend=fskit"   // macFUSE: no kernel extension, macOS 15.4+
        }
    }

    /// FSKit doesn't pass extended attributes through; the kernel stores them in the
    /// volume as AppleDouble files (`._name`). The volume icon then needs `._.`.
    var usesAppleDouble: Bool { self == .fuseTFSKit }

    /// FUSE-T's FSKit component. Its installer only adds it when run on macOS 26 or later.
    public static let fskitAppPath = "/Applications/fuse-t.app"

    /// Where the mount points go.
    /// - FUSE-T (NFS): Zippy's own state directory; a regular user may not mount under
    ///   /Volumes, and Finder shows the volumes anyway.
    /// - macFUSE: same; it could use /Volumes but leaves empty folders behind there.
    /// - FUSE-T via FSKit: `volumesFolder`. Finder only treats FSKit volumes as drives
    ///   (sidebar, desktop, eject) when they are under /Volumes.
    public func mountDirectory(stateDirectory: URL, volumesFolder: URL) -> URL {
        self == .fuseTFSKit ? volumesFolder : stateDirectory
    }

    /// Folder name of the mount point. With macFUSE, Finder shows this name in the
    /// sidebar (the volume name only in the window title). macFUSE 5.2 (FSKit, macOS 15)
    /// fails on spaces and non-ASCII characters in the path, so for macFUSE the name is
    /// rewritten: "My Archive" → "My-Archive", "Grüße" → "Grusse".
    public func directoryName(for name: String) -> String {
        guard self == .macFUSE else { return name }
        let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
        let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            .replacingOccurrences(of: "ß", with: "ss")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-()")
        var result = ""
        for scalar in plain.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result += "-"
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? String(localized: "Archive", bundle: .module) : result
    }

    /// Whether the library (and for FSKit, fuse-t.app) is present, without loading it.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: libraryPath)
            && (self != .fuseTFSKit || FileManager.default.fileExists(atPath: Self.fskitAppPath))
    }

    /// An explicit setting wins. Otherwise FUSE-T via FSKit when possible (macOS 26+,
    /// fuse-t.app present), else FUSE-T via NFS. Whether the FSKit extension is actually
    /// turned on only shows when mounting; the app checks /Volumes/Zippy beforehand.
    /// macFUSE only on request: on macOS 15 (macFUSE 5.2, FSKit) volumes are missing from
    /// the sidebar, only one volume works at a time, and failed mounts leave devices behind.
    public static func choose(setting: String?) -> FuseBackend {
        if let explicit = setting.flatMap(FuseBackend.init(rawValue:)) { return explicit }
        let fskitPossible = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        return fskitPossible && FuseBackend.fuseTFSKit.isInstalled ? .fuseTFSKit : .fuseT
    }
}
