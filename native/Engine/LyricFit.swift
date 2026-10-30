import Foundation

/// How the lyrics sit on the score. The transcribed score is divided into
/// sections (`% verse`, `% chorus`) and knows how many notes each one sings;
/// the lyrics are only lines and blank lines. Matching one to the other gives
/// the lyrics the section labels the music model expects, and shows where the
/// words and the melody do not fit, which is where a take tends to skip lines.
struct LyricFit: Equatable {
    struct Section: Equatable {
        var name: String
        /// When the section starts at the cover's tempo, in seconds.
        var start: Double
        /// Notes the vocal line begins in this section; tied notes count once.
        var notes: Int
        /// The lyric lines sung here, as indices into `lines`.
        var lines: Range<Int>
        var syllables: Int

        var label: String { "[" + Self.titled(name) + "]" }

        static func titled(_ name: String) -> String {
            var result = "", upper = true
            for character in name {
                result.append(upper ? Character(character.uppercased()) : character)
                upper = character == " " || character == "-"
            }
            return result
        }
    }

    enum Problem: Equatable {
        /// More syllables than the melody has notes: lines get crammed or skipped.
        case crowded(section: Int)
        /// A sung part of the score with no words: the singer borrows or jumps ahead.
        case wordless(section: Int)
        /// Words where the score has no melody.
        case instrumental(section: Int)
    }

    var sections: [Section]
    var lines: [String]
    var problems: [Problem]
    /// Whether the lyrics already had section labels of their own.
    var labelled: Bool

    /// Syllables sung per note, on average: the rest are held over several notes.
    private static let syllablesPerNote = 0.85
    /// Parts of a song that are often sung without words, or not sung at all.
    private static let sparse: Set<String> = ["intro", "interlude", "outro", "instrumental", "solo", "break", "inst"]

    /// Nil when the score has no sections or the lyrics have no lines.
    init?(lyrics: String, score: String, tempo: Double = 1) {
        let parsed = Self.sections(of: score, tempo: tempo)
        let verses = Self.lines(of: lyrics)
        guard !parsed.isEmpty, !verses.lines.isEmpty else { return nil }
        lines = verses.lines.map(\.text)
        labelled = verses.labelled
        let split = Self.assign(verses.lines, to: parsed, labelled: labelled)
        let matched = zip(parsed, split).map { section, range in
            Section(name: section.name, start: section.start, notes: section.notes, lines: range,
                    syllables: verses.lines[range].reduce(0) { $0 + $1.syllables })
        }
        sections = matched
        problems = matched.indices.compactMap { index in
            let section = matched[index]
            if section.lines.isEmpty {
                return section.notes >= 16 && !Self.sparse.contains(section.name) ? .wordless(section: index) : nil
            }
            if section.notes < 4 { return .instrumental(section: index) }
            return section.syllables > section.notes + max(3, section.notes / 8) ? .crowded(section: index) : nil
        }
    }

    /// Each problem as a sentence a person can act on.
    var messages: [String] {
        problems.map { problem in
            switch problem {
            case .crowded(let index):
                let section = sections[index]
                return "\(Section.titled(section.name)) at \(clockText(section.start)) has \(section.syllables) syllables for \(section.notes) notes. Lines there may be rushed or skipped."
            case .wordless(let index):
                return "\(Section.titled(sections[index].name)) at \(clockText(sections[index].start)) has a melody but no words. The singer may jump ahead or repeat lines."
            case .instrumental(let index):
                return "\(Section.titled(sections[index].name)) at \(clockText(sections[index].start)) has words but almost no melody to sing them on."
            }
        }
    }

    /// The lyrics with a label before each section's lines, or nil when they
    /// already have labels or the score gives nothing to label them with.
    static func labelled(_ lyrics: String, score: String) -> String? {
        guard let fit = LyricFit(lyrics: lyrics, score: score), !fit.labelled,
              fit.sections.contains(where: { !$0.name.isEmpty }) else { return nil }
        return fit.sections.filter { !$0.lines.isEmpty }.map { section in
            (section.name.isEmpty ? [] : [section.label]) + fit.lines[section.lines]
        }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    // MARK: Matching lines to sections

    /// Splits the lines into one run per section, in order, so each section's
    /// syllables are close to what its notes can carry. Too many words costs more
    /// than too few, since a singer can hold a note but not drop one, and an
    /// intro or outro may have no words at all. A split
    /// costs nothing at a blank line or a label, and something inside a verse.
    private static func assign(_ lines: [Line], to sections: [ScoreSection], labelled: Bool) -> [Range<Int>] {
        let notes = sections.map(\.notes)
        let count = lines.count
        var prefix = [0]
        for line in lines { prefix.append(prefix.last! + line.syllables) }
        func cost(_ section: Int, _ start: Int, _ end: Int) -> Double {
            let expected = Double(notes[section]) * syllablesPerNote
            let difference = Double(prefix[end] - prefix[start]) - expected
            let weight = difference >= 0 ? 1 : sparse.contains(sections[section].name) ? 0 : 0.4
            return weight * difference * difference / (expected + 12)
        }
        func splitting(at index: Int) -> Double {
            guard index > 0, index < count else { return 0 }
            if lines[index].opensSection { return 0 }
            return labelled ? 25 : lines[index].opensVerse ? 0 : 4
        }
        // best[k][j]: the cheapest way for the first k sections to sing the first j lines.
        var best = Array(repeating: Array(repeating: Double.infinity, count: count + 1), count: notes.count + 1)
        var from = Array(repeating: Array(repeating: 0, count: count + 1), count: notes.count + 1)
        best[0][0] = 0
        for section in notes.indices {
            for end in 0...count {
                for start in 0...end where best[section][start].isFinite {
                    let total = best[section][start] + cost(section, start, end) + (start < end ? splitting(at: start) : 0)
                    if total < best[section + 1][end] { best[section + 1][end] = total; from[section + 1][end] = start }
                }
            }
        }
        var ranges: [Range<Int>] = [], end = count
        for section in stride(from: notes.count, to: 0, by: -1) {
            let start = from[section][end]
            ranges.append(start..<end)
            end = start
        }
        return ranges.reversed()
    }

    // MARK: Lyrics

    struct Line: Equatable {
        var text: String
        var syllables: Int
        /// The line follows a blank line.
        var opensVerse: Bool
        /// The line follows a section label.
        var opensSection: Bool
    }

    static func lines(of lyrics: String) -> (lines: [Line], labelled: Bool) {
        var lines: [Line] = [], labelled = false, verse = true, section = false
        for raw in lyrics.components(separatedBy: .newlines) {
            let text = raw.trimmed
            if text.isEmpty { verse = true; continue }
            if text.matchesPattern(#"^\[[^\]]+\]$"#) { labelled = true; section = true; verse = true; continue }
            lines.append(Line(text: text, syllables: syllables(text), opensVerse: verse, opensSection: section))
            verse = false; section = false
        }
        return (lines, labelled)
    }

    /// A close count of sung syllables. Words in parentheses are backing vocals
    /// and are left out; kana, kanji and hangul count one each.
    static func syllables(_ text: String) -> Int {
        let sung = text.replacingPattern(#"\([^)]*\)"#, with: " ")
        let smallKana = Set("ぁぃぅぇぉゃゅょゎゕゖァィゥェォャュョヮヵヶ".unicodeScalars)
        var count = 0
        for word in sung.split(whereSeparator: { $0.isWhitespace || "-–—/".contains($0) }) {
            var latin = "", digits = false
            for scalar in word.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF: if !smallKana.contains(scalar), scalar != "・" { count += 1 }
                case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: count += 1
                default:
                    if CharacterSet.letters.contains(scalar) { latin.unicodeScalars.append(scalar) }
                    else if CharacterSet.decimalDigits.contains(scalar) { digits = true }
                }
            }
            count += latin.isEmpty ? (digits ? 1 : 0) : latinSyllables(latin.lowercased())
        }
        return count
    }

    private static func latinSyllables(_ word: String) -> Int {
        let vowels = Set("aeiouyàáâãäåæèéêëìíîïòóôõöøùúûüÿœ")
        var groups = 0, previous = false
        for character in word {
            let vowel = vowels.contains(character)
            if vowel && !previous { groups += 1 }
            previous = vowel
        }
        // A silent final e, as in "make" or "close", but not "little".
        if groups > 1, word.hasSuffix("e"), !word.hasSuffix("le"), !word.hasSuffix("ee") { groups -= 1 }
        return max(1, groups)
    }

    // MARK: The score

    struct ScoreSection: Equatable {
        var name: String
        var start: Double
        var notes: Int
    }

    /// The score's sections with the notes its vocal line begins in each. Empty
    /// when the score has no `%` section comments.
    static func sections(of score: String, tempo: Double = 1) -> [ScoreSection] {
        let header = score.components(separatedBy: .newlines)
        func field(_ key: String) -> String? {
            header.first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)).trimmed }
        }
        func fraction(_ text: String) -> Double? {
            let parts = text.split(separator: "/").compactMap { Double(String($0).trimmed) }
            return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : parts.count == 1 ? parts[0] : nil
        }
        let meter = field("M").flatMap { $0 == "C" ? 1 : $0 == "C|" ? 1 : fraction($0) } ?? 1
        let unit = field("L").flatMap(fraction) ?? 0.125
        // Q:1/4=94, or Q:94 in units of L.
        let marks = field("Q")?.split(separator: "=").map(String.init) ?? []
        let beat = marks.count == 2 ? fraction(marks[0]) ?? 0.25 : unit
        let perMinute = marks.last.flatMap { Double($0.trimmed) } ?? 120
        let barSeconds = meter / beat * 60 / max(1, perMinute) / max(0.1, tempo)

        let voices = header.filter { $0.hasPrefix("V:") }.compactMap { $0.dropFirst(2).split(separator: " ").first.map(String.init) }
        let vocal = voices.first { $0.localizedCaseInsensitiveContains("vocal") } ?? voices.first

        var sections: [ScoreSection] = [], voice = voices.first, bars = 0, tied = false, named = false
        for raw in header {
            let line = raw.trimmed
            if line.hasPrefix("%%") || line.isEmpty { continue }
            if line.hasPrefix("%") {
                let name = String(line.dropFirst()).trimmed
                if name.matchesPattern(#"^[\p{L}][\p{L}\d \-]*$"#) {
                    sections.append(ScoreSection(name: name.lowercased(), start: Double(bars) * barSeconds, notes: 0))
                    named = true
                }
                continue
            }
            if line.hasPrefix("V:") { voice = line.dropFirst(2).split(separator: " ").first.map(String.init); continue }
            if line.matchesPattern(#"^[A-Za-z]:"#) || voice != vocal { continue }
            if sections.isEmpty { sections.append(ScoreSection(name: "", start: 0, notes: 0)) }
            let music = line.replacingPattern(#""[^"]*"|![^!]*!|\+[^+]*\+|\{[^}]*\}|\[[A-Za-z]:[^\]]*\]|%.*$"#, with: " ")
            for measure in music.split(separator: "|").map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: ":] ")) }) where !measure.isEmpty {
                if let rest = measure.firstMatch(of: #/^Z(\d*)$/#) { bars += Int(rest.1) ?? 1 } else { bars += 1 }
            }
            for token in music.matches(of: #/(\[[^\]]*\]|[_^=]*[A-Ga-g][,']*|[zx])[\d\/]*(-?)/#) {
                let rest = token.1 == "z" || token.1 == "x"
                if !rest, !tied { sections[sections.count - 1].notes += 1 }
                tied = !rest && !token.2.isEmpty
            }
        }
        return named ? sections : []
    }
}
