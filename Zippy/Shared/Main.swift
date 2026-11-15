import AppKit

/// Entry point. The variant (FUSE or FSKit) gets the first chance to handle
/// command-line modes, e.g. the FUSE helper process (`--serve`).
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
