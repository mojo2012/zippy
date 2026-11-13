import FuseMount

/// FUSE-Variante: FUSE-T oder macFUSE, ein Hilfsprozess pro Volume.
enum Variant {
    /// `Zippy --serve <backend> <zip> <mountpunkt> <name>` startet den Hilfsprozess
    /// und kehrt nicht zurück.
    static func handleCommandLine() {
        let args = CommandLine.arguments
        if args.count == 6, args[1] == ServeCommand.flag, let backend = FuseBackend(rawValue: args[2]) {
            ServeCommand.run(backend: backend, archive: args[3], mountPoint: args[4], name: args[5])
        }
    }

    @MainActor static func makeMounter() -> any ArchiveMounting {
        FuseHelperMounter()
    }
}
