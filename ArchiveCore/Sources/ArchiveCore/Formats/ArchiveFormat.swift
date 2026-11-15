import CArchive

/// Archive format, detected from the content when opening.
///
/// The enum only names the format, so it can be compared (`archive.format == .rar`) and
/// passed around as a plain value. What a format can do lives in its
/// ``ArchiveFormatHandler``: ``ZipFormat``, ``TarFormat``, ``SevenZipFormat``, ``RarFormat``,
/// ``SQLiteFormat``.
public enum ArchiveFormat: Sendable, Equatable {
    case zip
    case tar(Compression)
    case sevenZip
    /// RAR 4 and 5. Read-only: libarchive can't write RAR.
    case rar
    /// SQLite database, shown read-only as one CSV and one DDL file per table and view.
    case sqlite

    /// Compression wrapped around a TAR.
    public enum Compression: Sendable, Equatable {
        case none, gzip, bzip2, compress, xz
    }

    /// The implementation of this format.
    var handler: any ArchiveFormatHandler {
        switch self {
        case .zip: ZipFormat()
        case .tar(let compression): TarFormat(compression: compression)
        case .sevenZip: SevenZipFormat()
        case .rar: RarFormat()
        case .sqlite: SQLiteFormat()
        }
    }

    /// The formats read through libarchive. A new libarchive format is added here and in
    /// ``handler``; other formats come with their own ``EntryReader``.
    static let libarchiveFormats: [any ArchiveFormatHandler] = [
        ZipFormat(), TarFormat(compression: .none), SevenZipFormat(), RarFormat(),
    ]

    /// Name of the document icon in Zippy/Resources/Icons.
    public var iconName: String { handler.iconName }

    /// For messages: "ZIP", "TAR", "7z", "RAR".
    public var displayName: String { handler.displayName }

    /// Whether Zippy can save changes in this format.
    public var isWritable: Bool { handler.isWritable }

    // archive.h: ARCHIVE_FORMAT_BASE_MASK, ARCHIVE_FORMAT_TAR, ARCHIVE_FORMAT_7ZIP, ARCHIVE_FORMAT_RAR(_V5)
    private static let formatMask: Int32 = 0xff0000
    private static let formatTar: Int32 = 0x30000
    private static let format7Zip: Int32 = 0xE0000
    private static let formatRar: Int32 = 0xD0000
    private static let formatRar5: Int32 = 0x100000

    /// The format a libarchive reader has detected (after the first header).
    init(detectedBy reader: OpaquePointer) {
        switch archive_format(reader) & Self.formatMask {
        case Self.formatTar:
            let compression: Compression = switch archive_filter_code(reader, 0) {
            case ARCHIVE_FILTER_GZIP: .gzip
            case ARCHIVE_FILTER_BZIP2: .bzip2
            case ARCHIVE_FILTER_COMPRESS: .compress
            case ARCHIVE_FILTER_XZ: .xz
            default: .none
            }
            self = .tar(compression)
        case Self.format7Zip:
            self = .sevenZip
        case Self.formatRar, Self.formatRar5:
            self = .rar
        default:
            self = .zip
        }
    }
}
