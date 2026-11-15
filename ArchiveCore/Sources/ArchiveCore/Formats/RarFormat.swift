import CArchive
import Foundation

/// RAR 4 and 5, read-only: libarchive can neither write RAR nor decrypt it.
struct RarFormat: ArchiveFormatHandler {
    var displayName: String { "RAR" }
    var iconName: String { "rar" }
    var isWritable: Bool { false }
    var canDecrypt: Bool { false }

    func enableReading(on reader: OpaquePointer) {
        archive_read_support_format_rar(reader)
        archive_read_support_format_rar5(reader)
    }

    func configureWriter(_ writer: OpaquePointer, password: String?) throws {
        throw ArchiveError.writeFailed(String(localized: "RAR archives can’t be written", bundle: .module))
    }
}
