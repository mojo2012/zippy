import CArchive

/// TAR, plain or compressed with gzip, bzip2, compress (.Z) or xz.
/// TAR has no encryption.
struct TarFormat: ArchiveFormatHandler {
    let compression: ArchiveFormat.Compression

    var displayName: String { "TAR" }
    var iconName: String { "tgz" }

    func enableReading(on reader: OpaquePointer) {
        archive_read_support_format_tar(reader)
        archive_read_support_filter_gzip(reader)
        archive_read_support_filter_bzip2(reader)
        archive_read_support_filter_compress(reader)
        archive_read_support_filter_xz(reader)
    }

    func configureWriter(_ writer: OpaquePointer, password: String?) throws {
        try rejectPassword(password)
        // pax: long names, UTF-8, nanoseconds; no pax extensions where not needed
        try check(archive_write_set_format_pax_restricted(writer), writer)
        let status: Int32 = switch compression {
        case .none: ARCHIVE_OK
        case .gzip: archive_write_add_filter_gzip(writer)
        case .bzip2: archive_write_add_filter_bzip2(writer)
        case .compress: archive_write_add_filter_compress(writer)
        case .xz: archive_write_add_filter_xz(writer)
        }
        try check(status, writer)
    }
}
