import Foundation

/// Erkennt geteilte Archive und findet ihre Teile in der richtigen Reihenfolge.
///
/// - `Name.part1.rar`, `Name.part01.rar` …  (RAR ab Version 3)
/// - `Name.rar`, `Name.r00`, `Name.r01` …  (älteres RAR-Schema)
/// - `Name.7z.001`, `Name.zip.001` …       (von 7-Zip zerschnitten, beliebiges Format)
///
/// Egal welcher Teil geöffnet wird: Es zählt immer der ganze Satz, beginnend beim ersten.
/// `Name.z01` (geteilte ZIPs von Info-ZIP/WinZip) ist anders aufgebaut und geht nicht.
public enum ArchiveParts {
    /// Alle Teile, erster zuerst. `nil`, wenn `url` kein Teil eines geteilten Archivs ist.
    /// Wirft, wenn ein Teil fehlt.
    public static func parts(for url: URL) throws -> [URL]? {
        guard let set = PartSet(url) else { return nil }
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // Gefundene Teile nach Nummer; Groß-/Kleinschreibung wie im Finder egal
        var numbered: [Int: String] = [:]
        for name in names {
            if let number = set.number(of: name) { numbered[number] = name }
        }
        guard let last = numbered.keys.max() else { return nil }
        var result: [URL] = []
        for number in set.first...last {
            guard let name = numbered[number] else {
                throw ArchiveError.openFailed(String(localized: "part \(set.displayName(of: number)) of the split archive is missing", bundle: .module))
            }
            result.append(directory.appendingPathComponent(name))
        }
        return result
    }

    /// Der erste Teil, über den das Archiv geöffnet und gemerkt wird; sonst `url` selbst.
    public static func firstPart(of url: URL) -> URL {
        (try? parts(for: url))??.first ?? url
    }

    /// Dateiname, als wäre es ein ungeteiltes Archiv: "Fotos.part01.rar" → "Fotos.rar",
    /// "Fotos.r00" → "Fotos.rar", "Fotos.7z.001" → "Fotos.7z".
    static func wholeName(of url: URL) -> String? {
        guard let set = PartSet(url) else { return nil }
        switch set.kind {
        case .rarPart, .rarOld: return set.base + ".rar"
        case .numbered: return set.base
        }
    }

    private struct PartSet {
        let base: String
        let first: Int
        let kind: Kind

        enum Kind { case rarPart(digits: Int), rarOld, numbered(digits: Int) }

        init?(_ url: URL) {
            let name = url.lastPathComponent
            if let match = name.wholeMatch(of: /(?i)(.+)\.part(\d+)\.rar/) {
                base = String(match.1); first = 1; kind = .rarPart(digits: match.2.count)
            } else if let match = name.wholeMatch(of: /(?i)(.+)\.r(\d\d)/) {
                base = String(match.1); first = 0; kind = .rarOld
            } else if let match = name.wholeMatch(of: /(?i)(.+)\.rar/),
                      FileManager.default.fileExists(atPath: url.deletingLastPathComponent()
                          .appendingPathComponent(match.1 + ".r00").path) {
                base = String(match.1); first = 0; kind = .rarOld
            } else if let match = name.wholeMatch(of: /(.+\.[A-Za-z0-9]+)\.(\d{3,})/) {
                base = String(match.1); first = 1; kind = .numbered(digits: match.2.count)
            } else {
                return nil
            }
        }

        /// Nummer eines Teils dieses Satzes. Beim alten RAR-Schema ist `.rar` der erste (0),
        /// `.r00` der zweite (1) usw.
        func number(of name: String) -> Int? {
            let lower = name.lowercased(), base = self.base.lowercased()
            switch kind {
            case .rarPart:
                guard let match = lower.wholeMatch(of: /(.+)\.part(\d+)\.rar/), String(match.1) == base else { return nil }
                return Int(match.2)
            case .rarOld:
                if lower == base + ".rar" { return 0 }
                guard let match = lower.wholeMatch(of: /(.+)\.r(\d\d)/), String(match.1) == base else { return nil }
                return Int(match.2).map { $0 + 1 }
            case .numbered:
                guard let match = lower.wholeMatch(of: /(.+)\.(\d{3,})/), String(match.1) == base else { return nil }
                return Int(match.2)
            }
        }

        func displayName(of number: Int) -> String {
            switch kind {
            case .rarPart(let digits): "\(base).part\(String(format: "%0\(digits)d", number)).rar"
            case .rarOld: number == 0 ? "\(base).rar" : "\(base).r\(String(format: "%02d", number - 1))"
            case .numbered(let digits): "\(base).\(String(format: "%0\(digits)d", number))"
            }
        }
    }
}
