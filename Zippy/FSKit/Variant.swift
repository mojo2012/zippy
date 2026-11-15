/// FSKit variant: Zippy's own file system extension (ZippyFS), App Store compatible.
enum Variant {
    /// No command-line modes: the extension provides the volumes.
    static func handleCommandLine() {}

    @MainActor static func makeMounter() -> any ArchiveMounting {
        FSKitMounter()
    }

    /// No settings in this variant.
    @MainActor static func showSettings(onClose: @escaping @MainActor () -> Void) -> Bool { false }
}
