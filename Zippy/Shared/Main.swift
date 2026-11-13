import AppKit

/// Einstieg. Die Variante (FUSE oder FSKit) darf vorher Kommandozeilen-Modi
/// übernehmen, z. B. den FUSE-Hilfsprozess (`--serve`).
@main
enum Main {
    static func main() {
        Variant.handleCommandLine()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
