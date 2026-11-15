import Foundation
import Testing
@testable import ArchiveCore

// Shared helpers for the test suites. Test archives are built at runtime with the
// system tools (/usr/bin/zip, /usr/bin/tar) or, for encrypted 7z, Homebrew's 7zz.

let sevenZipTool = "/opt/homebrew/bin/7zz"
let has7zz = FileManager.default.isExecutableFile(atPath: sevenZipTool)

/// A short random string for unique file names within a test directory.
func uniqueName() -> String { String(UUID().uuidString.prefix(8)) }

/// Creates a fresh temporary directory for one test.
func makeTempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zippy-\(prefix)-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes `files` (relative path -> contents) into a new source folder inside `dir`.
func makeSourceDir(in dir: URL, files: [String: Data]) throws -> URL {
    let src = dir.appendingPathComponent("src-\(uniqueName())", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    for (path, data) in files {
        let file = src.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }
    return src
}

/// Runs a command line tool, expects exit status 0 and returns its standard output.
@discardableResult
func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments.joined(separator: " ")) failed")
    return output
}

/// Packs `files` with `zip -r <flags>`. `prepare` may add more to the source folder first.
func makeZip(in dir: URL, _ files: [String: Data], flags: [String] = [], name: String? = nil,
             prepare: ((URL) throws -> Void)? = nil) throws -> URL {
    let src = try makeSourceDir(in: dir, files: files)
    try prepare?(src)
    let zip = dir.appendingPathComponent(name ?? "test-\(uniqueName()).zip")
    try run("/usr/bin/zip", ["-q", "-r"] + flags + [zip.path, "."], in: src)
    return zip
}

/// Packs `files` with `tar -c<flags>f`, e.g. "z" for gzip.
func makeTar(in dir: URL, _ files: [String: Data], flags: String = "", name: String? = nil,
             prepare: ((URL) throws -> Void)? = nil) throws -> URL {
    let src = try makeSourceDir(in: dir, files: files)
    try prepare?(src)
    let tar = dir.appendingPathComponent(name ?? "test-\(uniqueName()).tar")
    try run("/usr/bin/tar", ["-c\(flags)f", tar.path, "-C", src.path, "."])
    return tar
}

/// Packs `files` as 7z with the system tar (bsdtar writes LZMA1, solid).
func make7z(in dir: URL, _ files: [String: Data], options: [String] = [], name: String? = nil) throws -> URL {
    let src = try makeSourceDir(in: dir, files: files)
    let archive = dir.appendingPathComponent(name ?? "test-\(uniqueName()).7z")
    try run("/usr/bin/tar", ["--format", "7zip"] + options + ["-cf", archive.path, "-C", src.path, "."])
    return archive
}

/// Packs `files` as an encrypted 7z with `7zz`, optionally encrypting the file names too.
func makeEncrypted7z(in dir: URL, _ files: [String: Data], password: String, encryptedNames: Bool) throws -> URL {
    let src = try makeSourceDir(in: dir, files: files)
    let archive = dir.appendingPathComponent("encrypted-\(uniqueName()).7z")
    try run(sevenZipTool, ["a", "-bso0", "-p\(password)", "-mhe=\(encryptedNames ? "on" : "off")", archive.path, "."],
            in: src)
    return archive
}

/// A RAR test archive from libarchive, bundled in `Fixtures`.
func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
}

extension Archive {
    /// Contents of the entry at `path`, or nil if there is none.
    func data(at path: String) throws -> Data? {
        guard let entry = index.lookup(path: path) else { return nil }
        return try contents(of: entry.id)
    }

    /// Contents of the entry at `path` as UTF-8 text, or nil if there is none.
    func text(at path: String) throws -> String? {
        try data(at: path).map { String(decoding: $0, as: UTF8.self) }
    }
}
