import ArchiveCore
import Foundation

// Small tool for trying out the core without mounting:
//   archivetool ls  <archive.zip>
//   archivetool cat <archive.zip> <path/in/archive> [password]

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    Usage:
      archivetool ls  <archive.zip>
      archivetool cat <archive.zip> <path/in/archive> [password]

    """.utf8))
    exit(2)
}

func printTree(_ archive: Archive, _ id: UInt64, indent: String = "") {
    for entry in archive.index.children(of: id) {
        let suffix = switch entry.kind {
        case .directory: "/"
        case .symlink: " -> \(entry.symlinkTarget ?? "?")"
        case .file: "  (\(entry.size) B\(entry.isEncrypted ? ", encrypted" : ""))"
        }
        print("\(indent)\(entry.name)\(suffix)")
        if entry.isDirectory { printTree(archive, entry.id, indent: indent + "  ") }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

do {
    let archive = try Archive(url: URL(fileURLWithPath: args[2]), password: args.count >= 5 ? args[4] : nil)
    switch args[1] {
    case "ls":
        printTree(archive, ArchiveIndex.rootID)
    case "cat" where args.count >= 4:
        guard let entry = archive.index.lookup(path: args[3]) else { throw ArchiveError.notFound }
        FileHandle.standardOutput.write(try archive.contents(of: entry.id))
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
