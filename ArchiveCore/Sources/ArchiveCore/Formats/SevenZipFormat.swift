import CArchive

/// 7z, written with LZMA2.
///
/// Decryption (AES-256, also of file names) works thanks to
/// scripts/patches/libarchive-7zip-aes.patch, but libarchive can't encrypt 7z. So an
/// encrypted 7z can't be saved with its password: silently writing it back unencrypted
/// would be a security hole. Removing the password on purpose is fine.
struct SevenZipFormat: ArchiveFormatHandler {
    var displayName: String { "7z" }
    var iconName: String { "7z" }
    var canSaveEncrypted: Bool { false }
    var canRemovePassword: Bool { true }
    /// 7z doesn't check the password: a wrong key yields garbage that only decompression
    /// notices ("Decompression failed", checksum errors).
    var verifiesPassword: Bool { false }

    func enableReading(on reader: OpaquePointer) {
        archive_read_support_format_7zip(reader)
    }

    func configureWriter(_ writer: OpaquePointer, password: String?) throws {
        try rejectPassword(password)
        try check(archive_write_set_format_7zip(writer), writer)
        try check(archive_write_set_options(writer, "7zip:compression=lzma2"), writer)
    }
}
