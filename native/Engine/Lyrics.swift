import Foundation

/// Lyric and subtitle files, reduced to the sung words: timings and markup are
/// removed, repeated lines and `[Section]` labels are kept.
enum LyricFile {
    static let extensions = ["txt", "srt", "lrc", "vtt", "ttml"]
    static let maximumLength = 18000

    static func parse(_ text: String, extension fileExtension: String) throws -> String {
        let kind = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if kind == "ttml" { return try checked(TimedText.lyrics(text)) }
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        let subtitles = kind == "srt" || kind == "vtt"
        var result: [String] = []
        var inMetadata = false
        for (index, raw) in lines.enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if kind == "vtt" {
                if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                    inMetadata = true
                    continue
                }
                if inMetadata {
                    if line.isEmpty { inMetadata = false }
                    continue
                }
                if ["WEBVTT", "Kind:", "Language:", "X-TIMESTAMP-MAP"].contains(where: line.hasPrefix) { continue }
            }
            if subtitles, line.contains("-->") || (!line.isEmpty && index + 1 < lines.count && lines[index + 1].contains("-->")) {
                continue
            }
            if kind == "lrc" {
                if line.matchesPattern(#"^\[(?:ar|ti|al|by|offset|length|re|ve):"#, caseInsensitive: true) { continue }
                line = line.replacingPattern(#"\[\d+:\d+(?:[.:]\d+)?\]"#, with: "").replacingPattern(#"<\d+:\d+(?:[.:]\d+)?>"#, with: "")
            }
            if subtitles || kind == "lrc" {
                line = unescapeHTML(line.replacingPattern(#"<[^>]*>|\{\\[^}]*\}"#, with: ""))
            }
            if !line.isEmpty || !(result.last?.isEmpty ?? true) { result.append(line) }
        }
        return try checked(result.joined(separator: "\n"))
    }

    private static func checked(_ lyrics: String) throws -> String {
        let lyrics = lyrics.trimmed
        if lyrics.isEmpty { throw ServiceError("No lyric text was found in that file. Paste the words instead.") }
        if lyrics.unicodeScalars.count > maximumLength { throw ServiceError("Import lyrics up to 18,000 characters.") }
        return lyrics
    }

    /// The entities subtitle files use in practice: the XML five, `&nbsp;` and numeric references.
    static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            let entity = String(text[name])
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[entity]
            }
            result += text[last..<whole.lowerBound]
            result += replacement ?? String(text[whole])
            last = whole.upperBound
        }
        return result + text[last...]
    }
}

/// Timed-text lyrics (TTML, as Apple Music exports them): each `<p>` is a line,
/// each `<div>` a stanza, labelled by its song part when the file names one.
enum TimedText {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Child] = []
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

        /// An attribute by its local name, ignoring namespace prefix, hyphens and case.
        func attribute(_ name: String) -> String {
            attributes.first { key, _ in
                (key.split(separator: ":").last.map(String.init) ?? key).replacingOccurrences(of: "-", with: "").lowercased() == name
            }?.value ?? ""
        }
        var elements: [Node] { children.compactMap { if case .element(let node) = $0 { node } else { nil } } }
        /// This element and everything inside it, in document order.
        var descendants: [Node] { [self] + elements.flatMap(\.descendants) }
    }
    enum Child { case text(String), element(Node) }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        var stack: [Node] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            let node = Node(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(.element(node)) } else { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.children.append(.text(string)) }
        func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.children.append(.text(String(decoding: data, as: UTF8.self))) }
    }

    static func lyrics(_ text: String) throws -> String {
        let unreadable = ServiceError("That TTML file could not be read.")
        // TTML never declares entities, and refusing them keeps expansion attacks out.
        if text.matchesPattern("<!(?:DOCTYPE|ENTITY)", caseInsensitive: true) { throw unreadable }
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let parser = XMLParser(data: Data(body.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw unreadable }
        guard let content = root.descendants.first(where: { $0.name == "body" }) else {
            throw ServiceError("No lyric text was found in that file. Paste the words instead.")
        }
        // A stanza is whichever element holds the lines directly, however deeply divs nest.
        var result: [String] = []
        for stanza in content.descendants where stanza.elements.contains(where: { $0.name == "p" }) {
            var lines = stanza.elements.filter { $0.name == "p" }
                .flatMap { words($0).components(separatedBy: "\n") }
                .map { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            let part = stanza.attribute("songpart").trimmed
            if !part.isEmpty { lines.insert("[" + part.replacingPattern("(?<=[a-z])(?=[A-Z])", with: "-") + "]", at: 0) }
            if !result.isEmpty { result.append("") }
            result += lines
        }
        return result.joined(separator: "\n")
    }

    private static func words(_ element: Node) -> String {
        var parts = ""
        for child in element.children {
            switch child {
            case .text(let text):
                parts += text
            case .element(let node) where node.name == "br":
                parts += "\n"
            case .element(let node) where node.name == "span":
                let role = node.attribute("role")
                if role == "x-translation" || role == "x-roman" { continue }
                var inner = words(node)
                // Background vocals sit beside the lead line, in brackets.
                if role == "x-bg", !inner.trimmed.isEmpty {
                    inner = inner.trimmed
                    inner = inner.hasPrefix("(") ? " " + inner : " (\(inner))"
                }
                parts += inner
            case .element:
                continue
            }
        }
        return parts
    }
}

extension String {
    func matchesPattern(_ pattern: String, caseInsensitive: Bool = false) -> Bool {
        let expression = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        return expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)) != nil
    }

    func replacingPattern(_ pattern: String, with template: String) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}
