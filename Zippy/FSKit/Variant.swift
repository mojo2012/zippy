/// FSKit-Variante: eigene Dateisystem-Erweiterung (ZippyFS), App-Store-tauglich.
enum Variant {
    /// Keine Kommandozeilen-Modi: Das Volume stellt die Erweiterung bereit.
    static func handleCommandLine() {}

    @MainActor static func makeMounter() -> any ArchiveMounting {
        FSKitMounter()
    }
}
