import AppKit
import FuseMount

/// Zippy hat zwei Modi in derselben Programmdatei:
///
/// - **App** (normaler Start, z. B. Doppelklick auf ein ZIP): startet pro Archiv
///   einen Hilfsprozess, wartet bis das Volume da ist, öffnet ein Finder-Fenster
///   und beendet sich.
/// - **Hilfsprozess** (`--serve <backend> <zip> <mountpunkt> <name>`): stellt genau ein Volume
///   bereit und beendet sich, sobald es ausgehängt wird.
@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        // Zippy --serve <backend> <zip> <mountpunkt> <name>
        if args.count == 6, args[1] == ServeCommand.flag, let backend = FuseBackend(rawValue: args[2]) {
            ServeCommand.run(backend: backend, archive: args[3], mountPoint: args[4], name: args[5])
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
