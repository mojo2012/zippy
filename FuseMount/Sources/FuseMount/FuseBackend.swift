import Foundation

/// Welche FUSE-Implementierung das Volume bereitstellt. Alle sprechen libfuse 2,
/// der Code darüber ist derselbe.
public enum FuseBackend: String, CaseIterable, Sendable {
    /// FUSE-T: NFS-basiert, keine Systemerweiterung. Volumes erscheinen in der
    /// Finder-Seitenleiste als Freigaben unter dem Server „fuse-t“.
    case fuseT = "fuse-t"
    /// macFUSE über FSKit (`backend=fskit`): lokale Volumes. Experimentell, siehe
    /// ``choose(setting:)``.
    case macFUSE = "macfuse"
    /// FUSE-T über FSKit (`backend=fskit`, ab macOS 26, braucht /Applications/fuse-t.app
    /// mit eingeschalteter Erweiterung). Lokale Volumes unter /Volumes/Zippy: im Finder
    /// mit Seitenleiste, Schreibtischsymbol und Auswerfen, mehrere gleichzeitig.
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

    /// Zusätzliche Mount-Optionen.
    var extraOptions: String {
        switch self {
        case .fuseT: ",namedattr"         // erweiterte Attribute (Finder-Info fürs Volume-Symbol)
        case .macFUSE: ",backend=fskit"   // ohne Kernel-Erweiterung, ab macOS 15.4
        case .fuseTFSKit: ",backend=fskit"
        }
    }

    /// FSKit reicht erweiterte Attribute nicht durch; der Kernel legt sie als
    /// AppleDouble-Dateien (`._name`) ins Volume. Das Volume-Symbol braucht dann `._.`.
    var usesAppleDouble: Bool { self == .fuseTFSKit }

    /// Pfad der FSKit-Komponente von FUSE-T. Der Installer legt sie nur an, wenn er
    /// schon unter macOS 26 oder neuer läuft.
    public static let fskitAppPath = "/Applications/fuse-t.app"

    /// Wo die Mountpunkte liegen.
    /// - FUSE-T (NFS): in Zippys eigenem Ordner; nach /Volumes darf es als normaler
    ///   Nutzer nicht, im Finder erscheinen die Volumes trotzdem.
    /// - macFUSE: ebenso; es dürfte nach /Volumes, lässt dort aber leere Ordner zurück.
    /// - FUSE-T über FSKit: unter `volumesFolder`. Nur unter /Volumes behandelt der
    ///   Finder FSKit-Volumes als Laufwerke (Seitenleiste, Schreibtisch, Auswerfen).
    public func mountDirectory(stateDirectory: URL, volumesFolder: URL) -> URL {
        self == .fuseTFSKit ? volumesFolder : stateDirectory
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
            && (self != .fuseTFSKit || FileManager.default.fileExists(atPath: Self.fskitAppPath))
    }

    /// Ausdrücklich eingestellt gewinnt. Sonst FUSE-T über FSKit, wenn möglich (macOS 26+,
    /// fuse-t.app vorhanden), sonst FUSE-T über NFS. Ob die FSKit-Erweiterung auch
    /// eingeschaltet ist, zeigt erst der Mount; /Volumes/Zippy prüft die App vorher.
    /// macFUSE nur auf Wunsch: Auf macOS 15 (macFUSE 5.2, FSKit) fehlt die Seitenleiste,
    /// es geht nur ein Volume gleichzeitig, und gescheiterte Mounts hinterlassen Geräte.
    public static func choose(setting: String?) -> FuseBackend {
        if let explicit = setting.flatMap(FuseBackend.init(rawValue:)) { return explicit }
        let fskitPossible = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        return fskitPossible && FuseBackend.fuseTFSKit.isInstalled ? .fuseTFSKit : .fuseT
    }
}
