import CArchive
import Foundation

/// Everything that differs between archive formats.
///
/// Reading, building the index, extracting and saving are shared code: libarchive does
/// the actual format work for all of them. A format only answers the questions below.
/// The extension provides the defaults, much like an abstract base class; a format
/// overrides only what is different about it.
protocol ArchiveFormatHandler: Sendable {
    /// For messages: "ZIP", "TAR", "7z", "RAR".
    var displayName: String { get }

    /// Name of the document icon in Zippy/Resources/Icons.
    var iconName: String { get }

    /// Enables this format, and any compression filters it needs, on a libarchive reader.
    func enableReading(on reader: OpaquePointer)

    /// Whether Zippy can save changes in this format at all. Default: yes.
    var isWritable: Bool { get }

    /// Whether libarchive can decrypt encrypted entries in this format. Default: yes.
    var canDecrypt: Bool { get }

    /// Whether an archive containing encrypted files can be saved again with its
    /// encryption intact. Default: yes.
    var canSaveEncrypted: Bool { get }

    /// Whether Zippy can add or change a password. Default: no.
    var canSetPassword: Bool { get }

    /// Whether Zippy can decrypt the archive and save it without a password. Default: no.
    var canRemovePassword: Bool { get }

    /// Whether the format checks the password itself. If not, a wrong password only shows
    /// up as garbage that decompression trips over, so read errors on encrypted data mean
    /// "wrong password". Default: yes.
    var verifiesPassword: Bool { get }

    /// Sets up a libarchive writer: format, filters, options and, if `password` isn't nil,
    /// encryption. Throws if the format can't be written that way.
    func configureWriter(_ writer: OpaquePointer, password: String?) throws
}

extension ArchiveFormatHandler {
    var isWritable: Bool { true }
    var canDecrypt: Bool { true }
    var canSaveEncrypted: Bool { true }
    var canSetPassword: Bool { false }
    var canRemovePassword: Bool { false }
    var verifiesPassword: Bool { true }

    /// For formats Zippy can't encrypt.
    func rejectPassword(_ password: String?) throws {
        guard password != nil else { return }
        throw ArchiveError.writeFailed(
            String(localized: "\(displayName) archives can’t be saved with a password", bundle: .module))
    }

    /// Turns a failed libarchive call into ``ArchiveError/writeFailed(_:)``.
    func check(_ status: Int32, _ writer: OpaquePointer) throws {
        guard status == ARCHIVE_OK else { throw ArchiveError.writeFailed(Archive.message(writer)) }
    }
}
