import ExtensionFoundation
import FSKit

/// Entry point of the FSKit extension.
@main
struct ZippyFSExtension: UnaryFileSystemExtension {
    let fileSystem = ZipFileSystem()
}
