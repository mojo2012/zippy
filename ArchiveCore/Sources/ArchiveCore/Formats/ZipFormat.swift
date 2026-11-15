import CArchive

/// ZIP: read with ZipCrypto or WinZip AES, written with AES-256.
/// File names are never encrypted, so listing always works.
struct ZipFormat: ArchiveFormatHandler {
    var displayName: String { "ZIP" }
    var iconName: String { "zip" }
    var canSetPassword: Bool { true }
    var canRemovePassword: Bool { true }

    func enableReading(on reader: OpaquePointer) {
        archive_read_support_format_zip(reader)
    }

    func configureWriter(_ writer: OpaquePointer, password: String?) throws {
        try check(archive_write_set_format_zip(writer), writer)
        guard let password else { return }
        try check(archive_write_set_options(writer, "zip:encryption=aes256"), writer)
        try check(archive_write_set_passphrase(writer, password.precomposedStringWithCanonicalMapping), writer)
    }
}
