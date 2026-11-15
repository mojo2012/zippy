import Foundation
import FuseMount

/// FUSE variant: FUSE-T or macFUSE, one helper process per volume.
enum Variant {
    /// `Zippy --serve <backend> <archive> <mount point> <name>` runs the helper process
    /// and never returns.
    static func handleCommandLine() {
        let args = CommandLine.arguments
        if args.count == 6, args[1] == ServeCommand.flag, let backend = FuseBackend(rawValue: args[2]) {
            ServeCommand.run(backend: backend, archive: args[3], mountPoint: args[4], name: args[5])
        }
    }

    @MainActor static func makeMounter() -> any ArchiveMounting {
        FuseHelperMounter()
    }

    @MainActor private static var settings: SettingsWindow?

    /// Zippy was launched without an archive: show the settings window; `onClose` runs
    /// when it is closed.
    @MainActor static func showSettings(onClose: @escaping @MainActor () -> Void) -> Bool {
        // Leftover from an earlier attempt at a System Settings pane
        let oldPane = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/PreferencePanes/Zippy.prefPane")
        try? FileManager.default.removeItem(at: oldPane)

        settings = SettingsWindow { onClose() }
        settings?.show()
        return true
    }
}
