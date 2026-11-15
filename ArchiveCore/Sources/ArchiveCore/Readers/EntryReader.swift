import Foundation

/// Lists an archive's entries and extracts their contents.
///
/// ``Archive`` handles everything else (cache, passwords, reading at offsets) the same way
/// for all formats. Formats libarchive reads share ``LibarchiveEntryReader``; formats it
/// doesn't know bring their own reader, like ``SQLiteEntryReader``.
protocol EntryReader: AnyObject, Sendable {
    /// All entries; `archiveIndex` of a file is the `position` passed to ``extract(position:to:)``.
    var index: ArchiveIndex { get }
    var format: ArchiveFormat { get }

    /// Writes the complete contents of the file at `position` to `file`.
    func extract(position: Int, to file: URL) throws
}
