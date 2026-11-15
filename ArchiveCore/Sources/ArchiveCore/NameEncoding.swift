import Foundation

/// Guesses the encoding of file names that aren't valid UTF-8.
///
/// ZIPs without the UTF-8 flag store names in the code page of the system they were
/// created on: Windows uses the OEM code page (437/850 in Western Europe, 936/GBK in
/// China, 932 in Japan, 866 in Russia …), some tools the ANSI code page 1252. The archive
/// doesn't record which. macOS charset detection is unreliable for short names (it takes
/// "Grüße" in code page 437 for Japanese), so this uses a simple score instead: each
/// candidate decodes all affected names of an archive, and the one where most characters
/// fit its script wins.
enum NameEncoding {
    /// The encoding that decodes `names` most plausibly. On a tie, the earlier candidate
    /// wins.
    static func guess(for names: [Data]) -> String.Encoding {
        var best = (encoding: candidates[0].encoding, score: -Double.infinity)
        for candidate in candidates {
            guard let score = score(names, as: candidate) else { continue }
            if score > best.score { best = (candidate.encoding, score) }
        }
        return best.encoding
    }

    /// Decodes `data`; if that fails, as UTF-8 with replacement characters for invalid bytes.
    static func decode(_ data: Data, as encoding: String.Encoding) -> String {
        String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private enum Script { case latin, cyrillic, chinese, japanese, korean }

    private struct Candidate {
        let encoding: String.Encoding
        let script: Script
    }

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }

    private static let big5 = cf(.big5)

    private static let candidates: [Candidate] = [
        Candidate(encoding: cf(.dosLatin1), script: .latin),         // 850, Western Europe
        Candidate(encoding: cf(.dosLatinUS), script: .latin),        // 437, US
        Candidate(encoding: .windowsCP1252, script: .latin),
        Candidate(encoding: cf(.GB_18030_2000), script: .chinese),   // GBK, China
        Candidate(encoding: .shiftJIS, script: .japanese),           // 932
        Candidate(encoding: big5, script: .chinese),                 // Taiwan, Hong Kong
        Candidate(encoding: cf(.EUC_KR), script: .korean),           // 949
        Candidate(encoding: cf(.dosRussian), script: .cyrillic),     // 866
    ]

    /// For the "common Chinese character" check: what GB2312 (simplified) contains.
    private static let gb2312 = cf(.EUC_CN)

    /// Average over all non-ASCII characters, 1 = everything fits. `nil` if not decodable.
    private static func score(_ names: [Data], as candidate: Candidate) -> Double? {
        var total = 0.0, count = 0
        for name in names {
            guard let text = String(data: name, encoding: candidate.encoding) else { return nil }
            for character in text where !character.isASCII {
                total += value(of: character, in: candidate)
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    private static func value(of character: Character, in candidate: Candidate) -> Double {
        guard let scalar = character.unicodeScalars.first else { return -1 }
        let v = scalar.value
        let isLetter = scalar.properties.isAlphabetic
        switch candidate.script {
        case .latin:
            if v == 0xA0 { return 0.5 }    // no-break space (DOS 0xFF), does occur in names
            if v == 0xFF { return 0 }      // ÿ: the same 0xFF in Windows-1252, hardly ever meant in names
            return isLetter && (0xC0...0x24F).contains(v) ? 1 : -1
        case .cyrillic:
            return isLetter && (0x400...0x4FF).contains(v) ? 1 : -1
        case .chinese:
            guard (0x4E00...0x9FFF).contains(v) else { return -1 }
            // Big5 (traditional) ranks just behind common simplified characters
            if candidate.encoding == big5 { return 0.9 }
            return String(character).data(using: gb2312) != nil ? 1 : -1
        case .japanese:
            if (0x3040...0x30FF).contains(v) { return 1 }         // hiragana, katakana
            if (0x4E00...0x9FFF).contains(v) { return 0.8 }       // Kanji
            if (0xFF61...0xFF9F).contains(v) { return -0.5 }      // half-width katakana
            return -1
        case .korean:
            return (0xAC00...0xD7A3).contains(v) ? 1 : -1         // Hangul syllables
        }
    }
}
