import ExtensionFoundation
import FSKit

/// Einstiegspunkt der FSKit-Erweiterung.
@main
struct ZippyFSExtension: UnaryFileSystemExtension {
    let fileSystem = ZipFileSystem()
}
