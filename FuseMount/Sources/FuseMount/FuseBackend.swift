import Foundation

/// Welche FUSE-Implementierung das Volume bereitstellt. Beide sprechen libfuse 2,
/// der Code darüber ist derselbe.
public enum FuseBackend: String, CaseIterable, Sendable {
    /// FUSE-T: NFS-basiert, keine Systemerweiterung. Volumes erscheinen in der
    /// Finder-Seitenleiste als Freigaben unter dem Server „fuse-t“.
    case fuseT = "fuse-t"
    /// macFUSE über FSKit (`backend=fskit`): lokale Volumes. Experimentell, siehe
    /// ``choose(setting:)``.
    case macFUSE = "macfuse"

    public var displayName: String {
        switch self {
        case .fuseT: "FUSE-T"
        case .macFUSE: "macFUSE"
        }
    }

    public var downloadURL: URL {
        switch self {
        case .fuseT: URL(string: "https://www.fuse-t.org")!
        case .macFUSE: URL(string: "https://macfuse.github.io")!
        }
    }

    var libraryPath: String {
        switch self {
        case .fuseT: "/usr/local/lib/libfuse-t.dylib"
        case .macFUSE: "/usr/local/lib/libfuse.2.dylib"
        }
    }

    /// Zusätzliche Mount-Optionen.
    var extraOptions: String {
        switch self {
        case .fuseT: ",namedattr"         // erweiterte Attribute (Finder-Info fürs Volume-Symbol)
        case .macFUSE: ",backend=fskit"   // ohne Kernel-Erweiterung, ab macOS 15.4
        }
    }

    /// Wo die Mountpunkte liegen: bei beiden in Zippys eigenem Ordner.
    /// FUSE-T darf als normaler Nutzer nicht nach /Volumes. macFUSE dürfte, lässt
    /// beim Aushängen (FSKit, macOS 15) aber leere Ordner in /Volumes zurück, die
    /// nur root löschen kann. Im Finder erscheinen die Volumes trotzdem normal.
    public func mountDirectory(stateDirectory: URL) -> URL {
        stateDirectory
    }

    /// Ordnername des Mountpunkts. Der Finder zeigt bei macFUSE diesen Namen in der
    /// Seitenleiste an (den Volumenamen nur im Fenstertitel). macFUSE 5.2 (FSKit,
    /// macOS 15) scheitert an Leerzeichen und Nicht-ASCII-Zeichen im Pfad, darum
    /// wird dort umgeschrieben: "Mein Archiv" → "Mein-Archiv", "Grüße" → "Grusse".
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
        return result.isEmpty ? "Archiv" : result
    }

    /// Prüft, ob die Bibliothek vorhanden ist (ohne sie zu laden).
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: libraryPath)
    }

    /// Standard ist FUSE-T. macFUSE nur, wenn ausdrücklich eingestellt: Auf macOS 15
    /// (macFUSE 5.2, FSKit) erscheinen die Volumes nicht in der Finder-Seitenleiste,
    /// es geht nur eines gleichzeitig, und gescheiterte Mounts hinterlassen Geräte.
    public static func choose(setting: String?) -> FuseBackend {
        setting == FuseBackend.macFUSE.rawValue ? .macFUSE : .fuseT
    }
}
