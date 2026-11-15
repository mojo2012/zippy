import AppKit

/// Installiert Zippys Bereich für die Systemeinstellungen (`Zippy.prefPane`, steckt in
/// `Zippy.app/Contents/PlugIns`) nach `~/Library/PreferencePanes` und öffnet ihn.
/// Ersetzt eine ältere Kopie, damit die Pane zur App passt.
enum PreferencePaneInstaller {
    private static var bundled: URL? {
        Bundle.main.builtInPlugInsURL?.appendingPathComponent("Zippy.prefPane")
    }

    private static var installed: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/PreferencePanes/Zippy.prefPane")
    }

    /// `false`, wenn keine Pane mitgeliefert ist oder sie sich nicht installieren lässt.
    @MainActor static func installAndOpen() -> Bool {
        guard let bundled, FileManager.default.fileExists(atPath: bundled.path) else { return false }
        do {
            if !isSame(bundled, installed) {
                try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: installed.path) {
                    try FileManager.default.removeItem(at: installed)
                }
                try FileManager.default.copyItem(at: bundled, to: installed)
                log.info("Einstellungsbereich installiert: \(installed.path, privacy: .public)")
            }
        } catch {
            log.error("Einstellungsbereich: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return NSWorkspace.shared.open(installed)
    }

    /// Gleiche Programmdatei? (Versionsnummern ändern sich beim Entwickeln nicht.)
    private static func isSame(_ a: URL, _ b: URL) -> Bool {
        let binary = "Contents/MacOS/Zippy"
        guard let left = FileManager.default.contents(atPath: a.appendingPathComponent(binary).path),
              let right = FileManager.default.contents(atPath: b.appendingPathComponent(binary).path) else { return false }
        return left == right
    }
}
