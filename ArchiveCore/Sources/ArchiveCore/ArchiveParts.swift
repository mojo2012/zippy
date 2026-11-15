import Foundation

/// Detects split archives and finds their parts in the right order.
///
/// - `Name.part1.rar`, `Name.part01.rar` …  (RAR 3 and later)
/// - `Name.rar`, `Name.r00`, `Name.r01` …  (older RAR scheme)
/// - `Name.7z.001`, `Name.zip.001` …       (split by 7-Zip, any format)
///
/// Whichever part is opened, the whole set counts, starting with the first part.
/// `Name.z01` (Info-ZIP/WinZip split ZIPs) is structured differently and isn't supported.
public enum ArchiveParts {
    /// All parts, first part first. `nil` if `url` isn't part of a split archive.
    /// Throws if a part is missing.
    public static func parts(for url: URL) throws -> [URL]? {
        guard let set = PartSet(url) else { return nil }
        let directory = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // Parts found, by number; case-insensitive like Finder
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

    /// The first part, through which the archive is opened and remembered; otherwise `url` itself.
    public static func firstPart(of url: URL) -> URL {
        (try? parts(for: url))??.first ?? url
    }

    /// File name as if it were an unsplit archive: "Photos.part01.rar" → "Photos.rar",
    /// "Photos.r00" → "Photos.rar", "Photos.7z.001" → "Photos.7z".
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

        /// Number of a part of this set. In the old RAR scheme `.rar` is the first (0),
        /// `.r00` the second (1) and so on.
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
