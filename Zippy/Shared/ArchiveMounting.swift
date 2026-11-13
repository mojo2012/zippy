import Foundation

/// Die austauschbare Stelle zwischen App und Dateisystem-Technik.
///
/// Die App (``AppDelegate``) nimmt Archive entgegen, ruft ``mount(_:)`` auf,
/// öffnet den Mountpunkt im Finder und beendet sich. Wie das Volume entsteht,
/// weiß nur die Umsetzung:
///
/// - `Zippy/FUSE`: FUSE-T oder macFUSE, ein Hilfsprozess pro Volume
/// - `Zippy/FSKit`: Zippy-Image + DiskImageMounter + FSKit-Erweiterung
///
/// Welche Umsetzung in der App steckt, entscheidet allein das Target
/// (``Variant/makeMounter()``), nicht der Code.
@MainActor
protocol ArchiveMounting {
    /// Fehlt etwas Installierbares (z. B. FUSE-T), Name und Download-Adresse.
    var missingComponent: (name: String, downloadURL: URL)? { get }

    /// Reste früherer Läufe aufräumen. Wird vor dem ersten ``mount(_:)`` aufgerufen.
    func cleanUp()

    /// Mountet ein Archiv und liefert den Mountpunkt, sobald das Volume da ist.
    /// Ist das Archiv schon gemountet, kommt der vorhandene Mountpunkt zurück.
    func mount(_ archive: URL) async throws -> URL
}

struct MountError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
