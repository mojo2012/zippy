import ArchiveCore
import Foundation

// Kleines Werkzeug zum Ausprobieren des Kerns ohne Mounten:
//   archivetool ls  <archiv.zip>
//   archivetool cat <archiv.zip> <pfad/im/archiv>

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    Aufruf:
      archivetool ls  <archiv.zip>
      archivetool cat <archiv.zip> <pfad/im/archiv>

    """.utf8))
    exit(2)
}

func printTree(_ archive: ZipArchive, _ id: UInt64, indent: String = "") {
    for entry in archive.index.children(of: id) {
        let suffix = switch entry.kind {
        case .directory: "/"
        case .symlink: " -> \(entry.symlinkTarget ?? "?")"
        case .file: "  (\(entry.size) B\(entry.isEncrypted ? ", verschlüsselt" : ""))"
        }
        print("\(indent)\(entry.name)\(suffix)")
        if entry.isDirectory { printTree(archive, entry.id, indent: indent + "  ") }
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else { usage() }

do {
    let archive = try ZipArchive(url: URL(fileURLWithPath: args[2]))
    switch args[1] {
    case "ls":
        printTree(archive, ArchiveIndex.rootID)
    case "cat" where args.count == 4:
        guard let entry = archive.index.lookup(path: args[3]) else { throw ArchiveError.notFound }
        FileHandle.standardOutput.write(try archive.contents(of: entry.id))
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
    exit(1)
}
