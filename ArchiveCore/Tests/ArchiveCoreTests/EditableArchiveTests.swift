import Foundation
import Testing
@testable import ArchiveCore

/// Bearbeiten: Änderungen im Arbeitsordner, Speichern als neues ZIP.
@Suite struct EditableArchiveTests {
    let dir: URL
    let big = Data((0..<500_000).map { _ in UInt8.random(in: 0...255) })

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zippy-edit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func makeZip(_ files: [String: Data], arguments: [String] = []) throws -> URL {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        for (path, data) in files {
            let file = src.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let zip = dir.appendingPathComponent("test-\(UUID().uuidString.prefix(6)).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r"] + arguments + [zip.path, "."]
        process.currentDirectoryURL = src
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return zip
    }

    /// Speichert und öffnet das Ergebnis neu, wie beim nächsten Mounten.
    private func saveAndReopen(_ editable: EditableArchive, password: String? = nil) throws -> Archive {
        let output = dir.appendingPathComponent("out-\(UUID().uuidString.prefix(6)).zip")
        try editable.save(to: output)
        return try Archive(url: output, password: password)
    }

    private func text(_ archive: Archive, _ path: String) throws -> String? {
        guard let entry = archive.index.lookup(path: path) else { return nil }
        return String(decoding: try archive.contents(of: entry.id), as: UTF8.self)
    }

    @Test func unchangedArchiveHasNoChanges() throws {
        let editable = EditableArchive(archive: try Archive(url: makeZip(["a.txt": Data("a".utf8)])))
        #expect(!editable.hasChanges)
        #expect(editable.children(of: EditableArchive.rootID).map(\.name) == ["a.txt"])
    }

    @Test func addModifyDeleteRename() throws {
        let zip = try makeZip(["a.txt": Data("alt".utf8), "ordner/big.bin": big,
                               "weg.txt": Data("x".utf8), "ordner/b.txt": Data("b".utf8)])
        let editable = EditableArchive(archive: try Archive(url: zip))

        // neu
        let neu = try editable.createFile(at: "/neu.txt")
        try editable.write(neu.id, data: Data("frisch".utf8), at: 0)
        try editable.createDirectory(at: "leer")
        try editable.createDirectory(at: "Grüße")
        let deep = try editable.createFile(at: "Grüße/tief.txt")
        try editable.write(deep.id, data: Data("tief".utf8), at: 0)
        try editable.createSymlink(at: "link", target: "a.txt")
        // ändern: Original wird erst umkopiert, dann überschrieben
        let a = try #require(editable.node(at: "a.txt"))
        try editable.write(a.id, data: Data("NEU".utf8), at: 0)
        try editable.write(a.id, data: Data("!".utf8), at: 5)   // Lücke wird mit Nullen gefüllt
        // löschen, umbenennen, verschieben
        try editable.removeFile(at: "weg.txt")
        try editable.move(from: "ordner/b.txt", to: "b-umbenannt.txt")
        try editable.move(from: "ordner", to: "Grüße/ordner")
        #expect(editable.hasChanges)

        let saved = try saveAndReopen(editable)
        #expect(try text(saved, "neu.txt") == "frisch")
        #expect(try text(saved, "Grüße/tief.txt") == "tief")
        #expect(try text(saved, "a.txt") == "NEU\0\0!")
        #expect(saved.index.lookup(path: "weg.txt") == nil)
        #expect(try text(saved, "b-umbenannt.txt") == "b")
        #expect(saved.index.lookup(path: "ordner") == nil)
        let moved = try #require(saved.index.lookup(path: "Grüße/ordner/big.bin"))
        #expect(try saved.contents(of: moved.id) == big)
        #expect(saved.index.lookup(path: "leer")?.isDirectory == true)
        #expect(saved.index.lookup(path: "link")?.symlinkTarget == "a.txt")
    }

    /// Der Finder schickt Namen zerlegt (NFD). Im ZIP sollen sie zusammengesetzt
    /// stehen, mit UTF-8-Kennung, sonst zeigt Windows Zeichensalat.
    @Test func savesNamesAsUTF8NFC() throws {
        let editable = EditableArchive(archive: try Archive(url: makeZip(["a.txt": Data("a".utf8)])))
        try editable.createFile(at: "Gru\u{308}ße.txt")
        let output = dir.appendingPathComponent("namen.zip")
        try editable.save(to: output)

        // Rohe Bytes aus dem zentralen Verzeichnis: Flag 0x800 und NFC-Name
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
        let editable = EditableArchive(archive: try Archive(url: makeZip(["big.bin": big])))
        let node = try #require(editable.node(at: "big.bin"))
        try editable.truncate(node.id, to: 1000)
        #expect(editable.node(node.id)?.size == 1000)
        #expect(try editable.contents(of: node.id) == big.prefix(1000))
        try editable.truncate(node.id, to: 0)
        try editable.write(node.id, data: Data("kurz".utf8), at: 0)
        #expect(try text(saveAndReopen(editable), "big.bin") == "kurz")
    }

    @Test func posixErrors() throws {
        let editable = EditableArchive(archive: try Archive(url: makeZip(["d/x.txt": Data("x".utf8)])))
        #expect(throws: POSIXError(.EEXIST)) { try editable.createFile(at: "d/x.txt") }
        #expect(throws: POSIXError(.ENOENT)) { try editable.createFile(at: "fehlt/y.txt") }
        #expect(throws: POSIXError(.ENOTDIR)) { try editable.createFile(at: "d/x.txt/y") }
        #expect(throws: POSIXError(.ENOTEMPTY)) { try editable.removeDirectory(at: "d") }
        #expect(throws: POSIXError(.EPERM)) { try editable.removeFile(at: "d") }
        #expect(throws: POSIXError(.EINVAL)) { try editable.move(from: "d", to: "d/innen") }
        #expect(!editable.hasChanges)
    }

    @Test func renameReplacesExistingFile() throws {
        // So speichern viele Programme: neue Datei schreiben, dann über das Original schieben
        let editable = EditableArchive(archive: try Archive(url: makeZip(["doc.txt": Data("v1".utf8)])))
        let temp = try editable.createFile(at: ".doc.txt.sb-1234")
        try editable.write(temp.id, data: Data("v2".utf8), at: 0)
        try editable.move(from: ".doc.txt.sb-1234", to: "doc.txt")
        let saved = try saveAndReopen(editable)
        #expect(try text(saved, "doc.txt") == "v2")
        #expect(saved.index.entries.count == 2)   // Wurzel + doc.txt
    }

    @Test func systemFilesAreNotSaved() throws {
        let editable = EditableArchive(archive: try Archive(url: makeZip(["a.txt": Data("a".utf8)])))
        let store = try editable.createFile(at: ".DS_Store")
        try editable.write(store.id, data: Data("finder".utf8), at: 0)
        try editable.createDirectory(at: ".TemporaryItems")
        try editable.createFile(at: ".TemporaryItems/folders.501")
        try editable.createFile(at: "._a.txt")
        try editable.setExtendedAttribute("com.apple.FinderInfo", to: Data(count: 32), of: EditableArchive.rootID)
        #expect(editable.isSystemFile(store.id))
        #expect(!editable.hasChanges, "Finder-Kram allein ist keine Änderung")
        // Aus einem Systemordner an einen normalen Ort verschoben: wird gespeichert
        try editable.move(from: ".TemporaryItems/folders.501", to: "echt.txt")
        #expect(editable.hasChanges)

        let saved = try saveAndReopen(editable)
        #expect(Set(saved.index.children(of: ArchiveIndex.rootID).map(\.name)) == ["a.txt", "echt.txt"])
    }

    @Test func encryptedArchiveStaysEncrypted() throws {
        let zip = try makeZip(["geheim.txt": Data("geheim".utf8), "anders.txt": Data("x".utf8)],
                              arguments: ["-P", "pw"])
        let editable = EditableArchive(archive: try Archive(url: zip, password: "pw"))
        #expect(!editable.isReadOnly)
        let neu = try editable.createFile(at: "neu.txt")
        try editable.write(neu.id, data: Data("auch geheim".utf8), at: 0)

        let output = dir.appendingPathComponent("verschluesselt.zip")
        try editable.save(to: output)
        let saved = try Archive(url: output, password: "pw")
        #expect(saved.needsPassword)
        #expect(saved.index.entries.values.filter { $0.kind == .file }.allSatisfy { $0.isEncrypted })
        #expect(try text(saved, "geheim.txt") == "geheim")
        #expect(try text(saved, "neu.txt") == "auch geheim")
        let wrong = try Archive(url: output, password: "falsch")
        #expect(throws: ArchiveError.wrongPassword) { try wrong.checkPassword() }
    }

    @Test func encryptedWithoutPasswordIsReadOnly() throws {
        let zip = try makeZip(["geheim.txt": Data("geheim".utf8)], arguments: ["-P", "pw"])
        let editable = EditableArchive(archive: try Archive(url: zip))
        #expect(editable.isReadOnly)
        #expect(throws: POSIXError(.EROFS)) { try editable.createFile(at: "neu.txt") }
    }

    @Test func saveReplacingOriginal() throws {
        let zip = try makeZip(["a.txt": Data("a".utf8)])
        let stamp = try EditableArchive.FileStamp(of: zip)
        let editable = EditableArchive(archive: try Archive(url: zip))
        try editable.createFile(at: "b.txt")
        #expect(try editable.saveReplacing(zip, ifUnchangedSince: stamp) == zip)
        #expect(try Archive(url: zip).index.lookup(path: "b.txt") != nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".zippy-") }
        #expect(leftovers.isEmpty)
    }

    @Test func originalChangedElsewhereGetsCopy() throws {
        let zip = try makeZip(["a.txt": Data("a".utf8)])
        let stamp = try EditableArchive.FileStamp(of: zip)
        let editable = EditableArchive(archive: try Archive(url: zip))
        try editable.createFile(at: "b.txt")
        // Jemand anderes überschreibt das ZIP, während es gemountet ist
        let other = try Data(contentsOf: makeZip(["fremd.txt": Data("f".utf8)]))
        try other.write(to: zip)

        let target = try editable.saveReplacing(zip, ifUnchangedSince: stamp)
        #expect(target.lastPathComponent == zip.deletingPathExtension().lastPathComponent + " (\(EditableArchive.editedSuffix)).zip")
        #expect(try Data(contentsOf: zip) == other)
        #expect(try Archive(url: target).index.lookup(path: "b.txt") != nil)
    }
}
