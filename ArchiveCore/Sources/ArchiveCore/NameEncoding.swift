import Foundation

/// Rät die Kodierung von Dateinamen, die kein gültiges UTF-8 sind.
///
/// ZIPs ohne UTF-8-Kennung speichern Namen in der Codepage des Systems, auf dem sie
/// gepackt wurden: Windows nimmt die OEM-Codepage (437/850 in Westeuropa, 936/GBK in
/// China, 932 in Japan, 866 in Russland …), manche Programme die ANSI-Codepage 1252.
/// Im Archiv steht davon nichts. Die Zeichensatz-Erkennung von macOS ist bei kurzen
/// Namen unzuverlässig (sie hält „Grüße“ aus Codepage 437 für Japanisch), darum hier
/// eine einfache Bewertung: Jede Kandidatin dekodiert alle betroffenen Namen eines
/// Archivs; gewinnt die, bei der die meisten Zeichen zu ihrer Sprache passen.
enum NameEncoding {
    /// Die Kodierung, mit der `names` am plausibelsten lesbar sind. Reihenfolge = Vorrang
    /// bei Gleichstand.
    static func guess(for names: [Data]) -> String.Encoding {
        var best = (encoding: candidates[0].encoding, score: -Double.infinity)
        for candidate in candidates {
            guard let score = score(names, as: candidate) else { continue }
            if score > best.score { best = (candidate.encoding, score) }
        }
        return best.encoding
    }

    /// Dekodiert `data`; gelingt das nicht, mit Ersatzzeichen für ungültige Bytes.
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

    private static let candidates: [Candidate] = [
        Candidate(encoding: cf(.dosLatin1), script: .latin),         // 850, Westeuropa
        Candidate(encoding: cf(.dosLatinUS), script: .latin),        // 437, USA
        Candidate(encoding: .windowsCP1252, script: .latin),
        Candidate(encoding: cf(.GB_18030_2000), script: .chinese),   // GBK, China
        Candidate(encoding: .shiftJIS, script: .japanese),           // 932
        Candidate(encoding: cf(.big5), script: .chinese),            // Taiwan, Hongkong
        Candidate(encoding: cf(.EUC_KR), script: .korean),           // 949
        Candidate(encoding: cf(.dosRussian), script: .cyrillic),     // 866
    ]

    /// Für die Prüfung „häufiges chinesisches Zeichen“: Was GB2312 kennt (vereinfacht).
    private static let gb2312 = cf(.EUC_CN)

    /// Durchschnitt über alle Nicht-ASCII-Zeichen, 1 = alles passt. `nil`, wenn nicht dekodierbar.
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
            if v == 0xA0 { return 0.5 }    // geschütztes Leerzeichen (DOS 0xFF), kommt in Namen vor
            if v == 0xFF { return 0 }      // ÿ: dieselbe 0xFF in Windows-1252, in Namen kaum je gemeint
            return isLetter && (0xC0...0x24F).contains(v) ? 1 : -1
        case .cyrillic:
            return isLetter && (0x400...0x4FF).contains(v) ? 1 : -1
        case .chinese:
            guard (0x4E00...0x9FFF).contains(v) else { return -1 }
            // Big5 (traditionell) knapp hinter häufigen vereinfachten Zeichen
            if candidate.encoding == cf(.big5) { return 0.9 }
            return String(character).data(using: gb2312) != nil ? 1 : -1
        case .japanese:
            if (0x3040...0x30FF).contains(v) { return 1 }         // Hiragana, Katakana
            if (0x4E00...0x9FFF).contains(v) { return 0.8 }       // Kanji
            if (0xFF61...0xFF9F).contains(v) { return -0.5 }      // Halbbreite Katakana
            return -1
        case .korean:
            return (0xAC00...0xD7A3).contains(v) ? 1 : -1         // Hangul-Silben
        }
    }
}
