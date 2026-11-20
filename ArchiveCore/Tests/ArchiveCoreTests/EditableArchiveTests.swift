import Foundation
import Testing
@testable import ArchiveCore

/// Editing: changes live in a working folder and are saved as a new ZIP.
@Suite struct EditableArchiveTests {
    let dir: URL
    let big = Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })

    init() throws {
        dir = try makeTempDir("edit")
    }

    private func openEditable(_ files: [String: Data]) throws -> EditableArchive {
        EditableArchive(archive: try Archive(url: makeZip(in: dir, files)))
    }

    /// Saves and reopens the result, as on the next mount.
    private func saveAndReopen(_ editable: EditableArchive) throws -> Archive {
        let output = dir.appendingPathComponent("out-\(uniqueName()).zip")
        try editable.save(to: output)
        return try Archive(url: output)
    }

    @Test func unchangedArchiveHasNoChanges() throws {
        let editable = try openEditable(["a.txt": Data("a".utf8)])
        #expect(!editable.hasChanges)
        #expect(editable.children(of: EditableArchive.rootID).map(\.name) == ["a.txt"])
    }

    @Test func addModifyDeleteRename() throws {
        let editable = try openEditable(["a.txt": Data("old".utf8), "folder/big.bin": big,
                                     "gone.txt": Data("x".utf8), "folder/b.txt": Data("b".utf8)])

        // add
        let new = try editable.createFile(at: "/new.txt")
        try editable.write(new.id, data: Data("fresh".utf8), at: 0)
        try editable.createDirectory(at: "empty")
        try editable.createDirectory(at: "Grüße")
        let deep = try editable.createFile(at: "Grüße/deep.txt")
        try editable.write(deep.id, data: Data("deep".utf8), at: 0)
        try editable.createSymlink(at: "link", target: "a.txt")
        // modify: the original is copied out first, then overwritten
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEW".utf8), at: 0)
        try editable.write(a.id, data: Data("!".utf8), at: 5)   // the gap is filled with zeros
        // delete, rename, move
        try editable.removeFile(at: "gone.txt")
        try editable.move(from: "folder/b.txt", to: "b-renamed.txt")
        try editable.move(from: "folder", to: "Grüße/folder")
        #expect(editable.hasChanges)

        let saved = try saveAndReopen(editable)
        #expect(try saved.text(at: "new.txt") == "fresh")
        #expect(try saved.text(at: "Grüße/deep.txt") == "deep")
        #expect(try saved.text(at: "a.txt") == "NEW\0\0!")
        #expect(saved.index.lookup(path: "gone.txt") == nil)
        #expect(try saved.text(at: "b-renamed.txt") == "b")
        #expect(saved.index.lookup(path: "folder") == nil)
        #expect(try saved.data(at: "Grüße/folder/big.bin") == big)
        #expect(saved.index.lookup(path: "empty")?.isDirectory == true)
        #expect(saved.index.lookup(path: "link")?.symlinkTarget == "a.txt")
    }

    /// Finder sends names decomposed (NFD). In the ZIP they must be stored composed,
    /// with the UTF-8 flag set, or Windows shows garbage.
    @Test func savesNamesAsUTF8NFC() throws {
        let editable = try openEditable(["a.txt": Data("a".utf8)])
        try editable.createFile(at: "Gru\u{308}ße.txt")
        let output = dir.appendingPathComponent("names.zip")
        try editable.save(to: output)

        // Raw bytes from the central directory: flag 0x800 and the NFC name
        let data = try Data(contentsOf: output)
        let nfc = Array("Grüße.txt".precomposedStringWithCanonicalMapping.utf8)
        let signature: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
        let headers = (0..<data.count - 46).filter { Array(data[$0..<$0 + 4]) == signature }
        let entries = headers.map { offset -> (flags: UInt16, name: [UInt8]) in
            let flags = UInt16(data[offset + 8]) | UInt16(data[offset + 9]) << 8
            let length = Int(data[offset + 28]) | Int(data[offset + 29]) << 8
            return (flags, Array(data[offset + 46..<offset + 46 + length]))
        }
        let entry = try #require(entries.first { $0.name == nfc })
        #expect(entry.flags & 0x800 != 0)
    }

    @Test func truncateAndReadBack() throws {
        let editable = try openEditable(["big.bin": big])
        let node = try #require(editable.node(at: "big.bin"))
        try editable.truncate(node.id, to: 1000)
        #expect(editable.node(node.id)?.size == 1000)
        #expect(try editable.contents(of: node.id) == big.prefix(1000))
        try editable.truncate(node.id, to: 0)
        try editable.write(node.id, data: Data("short".utf8), at: 0)
        #expect(try saveAndReopen(editable).text(at: "big.bin") == "short")
    }

    /// Writing sets the modification date to now. FUSE-T then sets the date from before
    /// the write again when closing the file; that must not undo it.
    @Test func writingUpdatesModificationDate() throws {
        let editable = try openEditable(["a.txt": Data("a".utf8)])
        let node = try #require(editable.node(at: "a.txt"))
        let old = Date(timeIntervalSince1970: 1_500_000_000)
        try editable.setModificationDate(node.id, to: old)
        let start = Date()
        try editable.write(node.id, data: Data("b".utf8), at: 1)
        try editable.write(node.id, data: Data("c".utf8), at: 2)
        let written = try #require(editable.node(node.id)?.modificationDate)
        #expect(written >= start.addingTimeInterval(-1))
        try editable.setModificationDate(node.id, to: old)
        #expect(editable.node(node.id)?.modificationDate == written)
        let saved = try #require(try saveAndReopen(editable).index.lookup(path: "a.txt"))
        #expect(saved.modificationDate > old)

        // Any other date is set, e.g. by touch or a copy that keeps dates
        let other = Date(timeIntervalSince1970: 1_000_000_000)
        try editable.setModificationDate(node.id, to: other)
        #expect(editable.node(node.id)?.modificationDate == other)
        try editable.setModificationDate(node.id, to: old)
        #expect(editable.node(node.id)?.modificationDate == old)
    }

    @Test func posixErrors() throws {
        let editable = try openEditable(["d/x.txt": Data("x".utf8)])
        #expect(throws: POSIXError(.EEXIST)) { try editable.createFile(at: "d/x.txt") }
        #expect(throws: POSIXError(.ENOENT)) { try editable.createFile(at: "missing/y.txt") }
        #expect(throws: POSIXError(.ENOTDIR)) { try editable.createFile(at: "d/x.txt/y") }
        #expect(throws: POSIXError(.ENOTEMPTY)) { try editable.removeDirectory(at: "d") }
        #expect(throws: POSIXError(.EPERM)) { try editable.removeFile(at: "d") }
        #expect(throws: POSIXError(.EINVAL)) { try editable.move(from: "d", to: "d/inside") }
        #expect(!editable.hasChanges)
    }

    @Test func renameReplacesExistingFile() throws {
        // How many apps save: write a new file, then move it over the original
        let editable = try openEditable(["doc.txt": Data("v1".utf8)])
        let temp = try editable.createFile(at: ".doc.txt.sb-1234")
        try editable.write(temp.id, data: Data("v2".utf8), at: 0)
        try editable.move(from: ".doc.txt.sb-1234", to: "doc.txt")
        let saved = try saveAndReopen(editable)
        #expect(try saved.text(at: "doc.txt") == "v2")
        #expect(saved.index.entries.count == 2)   // root + doc.txt
    }

    @Test func systemFilesAreNotSaved() throws {
        let editable = try openEditable(["a.txt": Data("a".utf8)])
        let store = try editable.createFile(at: ".DS_Store")
        try editable.write(store.id, data: Data("finder".utf8), at: 0)
        try editable.createDirectory(at: ".TemporaryItems")
        try editable.createFile(at: ".TemporaryItems/folders.501")
        try editable.createFile(at: "._a.txt")
        try editable.setExtendedAttribute("com.apple.FinderInfo", to: Data(count: 32), of: EditableArchive.rootID)
        #expect(editable.isSystemFile(store.id))
        #expect(!editable.hasChanges, "Finder clutter alone is not a change")
        // Moved out of a system folder to a regular place: gets saved
        try editable.move(from: ".TemporaryItems/folders.501", to: "real.txt")
        #expect(editable.hasChanges)

        let saved = try saveAndReopen(editable)
        #expect(Set(saved.index.children(of: ArchiveIndex.rootID).map(\.name)) == ["a.txt", "real.txt"])
    }

    @Test func encryptedArchiveStaysEncrypted() throws {
        let zip = try makeZip(in: dir, ["secret.txt": Data("secret".utf8), "other.txt": Data("x".utf8)],
                              flags: ["-P", "pw"])
        let editable = EditableArchive(archive: try Archive(url: zip, password: "pw"))
        #expect(!editable.isReadOnly)
        let new = try editable.createFile(at: "new.txt")
        try editable.write(new.id, data: Data("also secret".utf8), at: 0)

        let output = dir.appendingPathComponent("encrypted.zip")
        try editable.save(to: output)
        let saved = try Archive(url: output, password: "pw")
        #expect(saved.needsPassword)
        #expect(saved.index.entries.values.filter { $0.kind == .file }.allSatisfy { $0.isEncrypted })
        #expect(try saved.text(at: "secret.txt") == "secret")
        #expect(try saved.text(at: "new.txt") == "also secret")
        let wrong = try Archive(url: output, password: "wrong")
        #expect(throws: ArchiveError.wrongPassword) { try wrong.checkPassword() }
    }

    @Test func encryptedWithoutPasswordIsReadOnly() throws {
        let zip = try makeZip(in: dir, ["secret.txt": Data("secret".utf8)], flags: ["-P", "pw"])
        let editable = EditableArchive(archive: try Archive(url: zip))
        #expect(editable.isReadOnly)
        #expect(throws: POSIXError(.EROFS)) { try editable.createFile(at: "new.txt") }
    }

    @Test func saveReplacingOriginal() throws {
        let zip = try makeZip(in: dir, ["a.txt": Data("a".utf8)])
        let stamp = try EditableArchive.FileStamp(of: zip)
        let editable = EditableArchive(archive: try Archive(url: zip))
        try editable.createFile(at: "b.txt")
        #expect(try editable.saveReplacing(zip, ifUnchangedSince: stamp) == zip)
        #expect(try Archive(url: zip).index.lookup(path: "b.txt") != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".zippy-") }
        #expect(leftovers.isEmpty)
    }

    @Test func originalChangedElsewhereGetsCopy() throws {
        let zip = try makeZip(in: dir, ["a.txt": Data("a".utf8)])
        let stamp = try EditableArchive.FileStamp(of: zip)
        let editable = EditableArchive(archive: try Archive(url: zip))
        try editable.createFile(at: "b.txt")
        // Someone else overwrites the ZIP while it is mounted
        let other = try Data(contentsOf: makeZip(in: dir, ["foreign.txt": Data("f".utf8)]))
        try other.write(to: zip)

        let target = try editable.saveReplacing(zip, ifUnchangedSince: stamp)
        #expect(target.lastPathComponent == zip.deletingPathExtension().lastPathComponent + " (\(EditableArchive.editedSuffix)).zip")
        #expect(try Data(contentsOf: zip) == other)
        #expect(try Archive(url: target).index.lookup(path: "b.txt") != nil)
    }
}
