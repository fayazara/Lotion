//
//  InlineMarkdown.swift
//  Lotion
//
//  Inline Markdown (emphasis, code, links) to attributed text and back. The
//  parser follows CommonMark's delimiter rules closely enough for notes; what
//  it does not model (HTML, inline images, footnotes, reference links) is kept
//  as `.lotionRaw` text and written back exactly as it was.
//

import AppKit

nonisolated enum InlineMarkdown {
    // MARK: - Parsing

    static func parse(_ string: String) -> NSAttributedString {
        if !string.contains(where: { "\\`*_~[<!&hw".contains($0) }) {
            return NSAttributedString(string: string)
        }
        var parser = Parser(Array(string.unicodeScalars))
        return parser.run()
    }

    private struct Delimiter {
        let char: Unicode.Scalar
        var count: Int
        let canOpen: Bool
        let canClose: Bool
        var active = true
        var opens: [NSAttributedString.Key] = []
        var closes: [NSAttributedString.Key] = []
    }

    private enum Token {
        case text(String)
        case delimiter(Int)
        case node(NSAttributedString)
    }

    private struct Parser {
        let c: [Unicode.Scalar]
        var tokens: [Token] = []
        var delimiters: [Delimiter] = []
        var buffer = ""

        init(_ scalars: [Unicode.Scalar]) { c = scalars }

        mutating func flush() {
            if !buffer.isEmpty {
                tokens.append(.text(buffer))
                buffer = ""
            }
        }

        mutating func run() -> NSAttributedString {
            var i = 0
            let n = c.count
            while i < n {
                let ch = c[i]
                switch ch {
                case "\\":
                    if i + 1 < n, isASCIIPunctuation(c[i + 1]) {
                        buffer.unicodeScalars.append(c[i + 1])
                        i += 2
                    } else if i + 1 < n, c[i + 1] == "\n" {
                        buffer.append("\n")
                        i += 2
                    } else {
                        buffer.append("\\")
                        i += 1
                    }
                case "`":
                    let run = runLength(at: i, of: "`")
                    if let close = closingBackticks(from: i + run, length: run) {
                        var content = String(String.UnicodeScalarView(c[(i + run)..<close]))
                        content = content.replacingOccurrences(of: "\n", with: " ")
                        if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "),
                           content.contains(where: { $0 != " " }) {
                            content = String(content.dropFirst().dropLast())
                        }
                        flush()
                        tokens.append(.node(NSAttributedString(string: content, attributes: [.lotionCode: true])))
                        i = close + run
                    } else {
                        buffer += String(repeating: "`", count: run)
                        i += run
                    }
                case "*", "_", "~":
                    let run = runLength(at: i, of: ch)
                    if ch == "~" && run != 2 {
                        buffer += String(repeating: "~", count: run)
                        i += run
                        continue
                    }
                    let before: Unicode.Scalar = i > 0 ? c[i - 1] : "\n"
                    let after: Unicode.Scalar = i + run < n ? c[i + run] : "\n"
                    let (canOpen, canClose) = flanking(ch, before: before, after: after)
                    flush()
                    delimiters.append(Delimiter(char: ch, count: run, canOpen: canOpen, canClose: canClose))
                    tokens.append(.delimiter(delimiters.count - 1))
                    i += run
                case "[":
                    if let (inner, url, end) = link(at: i) {
                        flush()
                        let text = NSMutableAttributedString(attributedString: InlineMarkdown.parse(inner))
                        text.addAttribute(.lotionLink, value: url, range: NSRange(location: 0, length: text.length))
                        tokens.append(.node(text))
                        i = end
                    } else {
                        // Footnotes, wiki links, reference links: keep the bracket as typed.
                        flush()
                        tokens.append(.node(NSAttributedString(string: "[", attributes: [.lotionRaw: true])))
                        i += 1
                    }
                case "!":
                    if i + 1 < n, c[i + 1] == "[", let (_, _, end) = link(at: i + 1) {
                        flush()
                        let source = String(String.UnicodeScalarView(c[i..<end]))
                        tokens.append(.node(NSAttributedString(string: source, attributes: [.lotionRaw: true])))
                        i = end
                    } else {
                        buffer.append("!")
                        i += 1
                    }
                case "<":
                    if let end = angleSpan(at: i) {
                        let inner = String(String.UnicodeScalarView(c[(i + 1)..<(end - 1)]))
                        flush()
                        if isAutolink(inner) {
                            tokens.append(.node(NSAttributedString(string: inner, attributes: [.lotionLink: inner])))
                        } else {
                            let source = String(String.UnicodeScalarView(c[i..<end]))
                            tokens.append(.node(NSAttributedString(string: source, attributes: [.lotionRaw: true])))
                        }
                        i = end
                    } else {
                        buffer.append("<")
                        i += 1
                    }
                case "h", "w":
                    if let end = bareURL(at: i) {
                        let url = String(String.UnicodeScalarView(c[i..<end]))
                        flush()
                        tokens.append(.node(NSAttributedString(string: url, attributes: [.lotionLink: url])))
                        i = end
                    } else {
                        buffer.unicodeScalars.append(ch)
                        i += 1
                    }
                default:
                    buffer.unicodeScalars.append(ch)
                    i += 1
                }
            }
            flush()
            processEmphasis()
            return emit()
        }

        // MARK: Emphasis

        mutating func processEmphasis() {
            guard delimiters.count > 1 else { return }
            var closer = 0
            while closer < delimiters.count {
                guard delimiters[closer].active, delimiters[closer].canClose, delimiters[closer].count > 0 else {
                    closer += 1
                    continue
                }
                let ch = delimiters[closer].char
                var opener = closer - 1
                var found = -1
                while opener >= 0 {
                    let o = delimiters[opener]
                    if o.active, o.char == ch, o.canOpen, o.count > 0 {
                        // CommonMark's rule of three.
                        let both = o.canClose || delimiters[closer].canOpen
                        if !(both && (o.count + delimiters[closer].count) % 3 == 0
                             && !(o.count % 3 == 0 && delimiters[closer].count % 3 == 0)) || ch == "~" {
                            found = opener
                            break
                        }
                    }
                    opener -= 1
                }
                guard found >= 0 else {
                    if !delimiters[closer].canOpen { delimiters[closer].active = false }
                    closer += 1
                    continue
                }
                let use: Int
                let key: NSAttributedString.Key
                if ch == "~" {
                    use = 2
                    key = .lotionStrike
                } else if delimiters[closer].count >= 2 && delimiters[found].count >= 2 {
                    use = 2
                    key = .lotionBold
                } else {
                    use = 1
                    key = .lotionItalic
                }
                delimiters[found].count -= use
                delimiters[found].opens.insert(key, at: 0)
                delimiters[closer].count -= use
                delimiters[closer].closes.append(key)
                for between in (found + 1)..<closer { delimiters[between].active = false }
                if delimiters[found].count == 0 { delimiters[found].active = false }
                if delimiters[closer].count == 0 {
                    delimiters[closer].active = false
                    closer += 1
                }
            }
        }

        func emit() -> NSAttributedString {
            let out = NSMutableAttributedString()
            var active: [NSAttributedString.Key: Int] = [:]
            func attributes() -> [NSAttributedString.Key: Any] {
                var result: [NSAttributedString.Key: Any] = [:]
                for (key, count) in active where count > 0 { result[key] = true }
                return result
            }
            for token in tokens {
                switch token {
                case .text(let string):
                    out.append(NSAttributedString(string: string, attributes: attributes()))
                case .node(let node):
                    let piece = NSMutableAttributedString(attributedString: node)
                    let attrs = attributes()
                    if !attrs.isEmpty {
                        piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
                    }
                    out.append(piece)
                case .delimiter(let index):
                    let d = delimiters[index]
                    for key in d.closes { active[key, default: 0] -= 1 }
                    if d.count > 0 {
                        out.append(NSAttributedString(string: String(repeating: Character(d.char), count: d.count), attributes: attributes()))
                    }
                    for key in d.opens { active[key, default: 0] += 1 }
                }
            }
            return out
        }

        // MARK: Scanning helpers

        func runLength(at i: Int, of ch: Unicode.Scalar) -> Int {
            var j = i
            while j < c.count, c[j] == ch { j += 1 }
            return j - i
        }

        func closingBackticks(from start: Int, length: Int) -> Int? {
            var j = start
            while j < c.count {
                if c[j] == "`" {
                    let run = runLength(at: j, of: "`")
                    if run == length { return j }
                    j += run
                } else {
                    j += 1
                }
            }
            return nil
        }

        /// `[text](url)` starting at the bracket: the text, the target, and the index after `)`.
        func link(at i: Int) -> (String, String, Int)? {
            var depth = 0
            var j = i
            var close = -1
            while j < c.count {
                let ch = c[j]
                if ch == "\\" { j += 2; continue }
                if ch == "`" {
                    let run = runLength(at: j, of: "`")
                    if let end = closingBackticks(from: j + run, length: run) { j = end + run; continue }
                    j += run
                    continue
                }
                if ch == "[" { depth += 1 }
                if ch == "]" {
                    depth -= 1
                    if depth == 0 { close = j; break }
                }
                if ch == "\n" && j + 1 < c.count && c[j + 1] == "\n" { return nil }
                j += 1
            }
            guard close > i, close + 1 < c.count, c[close + 1] == "(" else { return nil }
            var k = close + 2
            var parens = 1
            var destination = ""
            if k < c.count, c[k] == "<" {
                k += 1
                while k < c.count, c[k] != ">" { if c[k] == "\n" { return nil }; destination.unicodeScalars.append(c[k]); k += 1 }
                guard k < c.count else { return nil }
                k += 1
                while k < c.count, c[k] == " " { k += 1 }
                guard k < c.count, c[k] == ")" else { return nil }
                return (String(String.UnicodeScalarView(c[(i + 1)..<close])), destination, k + 1)
            }
            while k < c.count {
                let ch = c[k]
                if ch == "\\", k + 1 < c.count { destination.unicodeScalars.append(c[k + 1]); k += 2; continue }
                if ch == "(" { parens += 1 }
                if ch == ")" {
                    parens -= 1
                    if parens == 0 { break }
                }
                // A title or a space ends the destination; such links stay raw.
                if ch == " " || ch == "\n" { return nil }
                destination.unicodeScalars.append(ch)
                k += 1
            }
            guard k < c.count, c[k] == ")" else { return nil }
            return (String(String.UnicodeScalarView(c[(i + 1)..<close])), destination, k + 1)
        }

        /// The end (after `>`) of an autolink or an inline HTML tag at `<`.
        func angleSpan(at i: Int) -> Int? {
            guard i + 1 < c.count else { return nil }
            let next = c[i + 1]
            guard next.properties.isAlphabetic || next == "/" || next == "!" || next == "?" else { return nil }
            var j = i + 1
            while j < c.count {
                if c[j] == ">" { return j + 1 }
                if c[j] == "<" || c[j] == "\n" { return nil }
                j += 1
            }
            return nil
        }

        func isAutolink(_ inner: String) -> Bool {
            if inner.contains(" ") { return false }
            if let colon = inner.firstIndex(of: ":") {
                let scheme = inner[..<colon]
                return scheme.count >= 2 && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+.-".contains($0) }
            }
            return inner.contains("@") && inner.contains(".")
        }

        /// The end of a bare `https://…` or `www.…` URL starting at `i`.
        func bareURL(at i: Int) -> Int? {
            if i > 0 {
                let previous = c[i - 1]
                if previous.properties.isAlphabetic || previous.properties.numericType != nil || previous == "/" { return nil }
            }
            func matches(_ prefix: String) -> Bool {
                var j = i
                for scalar in prefix.unicodeScalars {
                    guard j < c.count, c[j] == scalar else { return false }
                    j += 1
                }
                return true
            }
            let prefixLength: Int
            if matches("https://") { prefixLength = 8 } else if matches("http://") { prefixLength = 7 } else if matches("www.") { prefixLength = 4 } else { return nil }
            var j = i + prefixLength
            while j < c.count, !c[j].properties.isWhitespace, c[j] != "<" { j += 1 }
            // Trailing punctuation belongs to the sentence, and an unbalanced `)` to its parentheses.
            while j > i + prefixLength {
                let last = c[j - 1]
                if ".,:;!?\"'*_~".unicodeScalars.contains(last) { j -= 1; continue }
                if last == ")" {
                    let opens = c[i..<j].filter { $0 == "(" }.count
                    let closes = c[i..<j].filter { $0 == ")" }.count
                    if closes > opens { j -= 1; continue }
                }
                break
            }
            return j > i + prefixLength ? j : nil
        }
    }

    // MARK: - Character classes

    static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 33 && v <= 47) || (v >= 58 && v <= 64) || (v >= 91 && v <= 96) || (v >= 123 && v <= 126)
    }

    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return isASCIIPunctuation(scalar) }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII { return scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" }
        return scalar.properties.isWhitespace
    }

    /// Whether a delimiter run can open and close emphasis, per CommonMark.
    static func flanking(_ ch: Unicode.Scalar, before: Unicode.Scalar, after: Unicode.Scalar) -> (open: Bool, close: Bool) {
        let left = !isWhitespace(after) && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before))
        let right = !isWhitespace(before) && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        if ch == "_" {
            return (left && (!right || isPunctuation(before)), right && (!left || isPunctuation(after)))
        }
        return (left, right)
    }

    // MARK: - Writing

    static func write(_ text: NSAttributedString) -> String {
        let length = text.length
        guard length > 0 else { return "" }
        var hasSemantics = false
        text.enumerateAttributes(in: NSRange(location: 0, length: length)) { attrs, _, stop in
            if NSAttributedString.Key.semanticKeys.contains(where: { attrs[$0] != nil }) {
                hasSemantics = true
                stop.pointee = true
            }
        }
        if !hasSemantics { return escape(text.string, context: Array(text.string.unicodeScalars), offset: 0) }

        let trimmed = trimmingFormatWhitespace(text)
        let context = Array(trimmed.string.unicodeScalars)
        var out = ""
        var stack: [NSAttributedString.Key] = []
        let order: [NSAttributedString.Key] = [.lotionStrike, .lotionBold, .lotionItalic]
        let marks: [NSAttributedString.Key: String] = [.lotionStrike: "~~", .lotionBold: "**", .lotionItalic: "*"]

        func closeAll() {
            while let key = stack.popLast() { out += marks[key]! }
        }


        func adjust(to wanted: Set<NSAttributedString.Key>) {
            // Close down to what stays open, then open the rest outermost first.
            while let top = stack.last, !wanted.contains(top) || stack.contains(where: { !wanted.contains($0) }) {
                out += marks[stack.removeLast()]!
            }
            for key in order where wanted.contains(key) && !stack.contains(key) {
                stack.append(key)
                out += marks[key]!
            }
        }

        let full = NSRange(location: 0, length: trimmed.length)
        let string = trimmed.string as NSString
        var index = 0
        while index < trimmed.length {
            var range = NSRange()
            let attrs = trimmed.attributes(at: index, longestEffectiveRange: &range, in: full)
            // A link takes every run that shares its target.
            if let url = attrs[.lotionLink] as? String {
                var linkRange = NSRange()
                _ = trimmed.attribute(.lotionLink, at: index, longestEffectiveRange: &linkRange, in: full)
                let wanted = Set(order.filter { key in
                    var all = true
                    trimmed.enumerateAttribute(key, in: linkRange) { value, _, stop in
                        if value == nil { all = false; stop.pointee = true }
                    }
                    return all
                })
                adjust(to: wanted)
                let inner = NSMutableAttributedString(attributedString: trimmed.attributedSubstring(from: linkRange))
                let innerRange = NSRange(location: 0, length: inner.length)
                inner.removeAttribute(.lotionLink, range: innerRange)
                for key in wanted { inner.removeAttribute(key, range: innerRange) }
                let label = write(inner)
                if label == url, url.hasPrefix("http://") || url.hasPrefix("https://"), !url.contains(" ") {
                    out += url
                } else if label == url, !url.contains(" "), isEmailOrScheme(url) {
                    out += "<\(url)>"
                } else {
                    out += "[\(label)](\(writeDestination(url)))"
                }
                index = NSMaxRange(linkRange)
                continue
            }
            if attrs[.lotionRaw] != nil {
                adjust(to: Set(order.filter { attrs[$0] != nil }))
                out += string.substring(with: range)
                index = NSMaxRange(range)
                continue
            }
            adjust(to: Set(order.filter { attrs[$0] != nil }))
            let piece = string.substring(with: range)
            if attrs[.lotionCode] != nil {
                out += codeSpan(piece)
            } else {
                out += escape(piece, context: context, offset: utf16ToScalarOffset(string, range.location))
            }
            index = NSMaxRange(range)
        }
        closeAll()
        return out
    }

    private static func isEmailOrScheme(_ url: String) -> Bool {
        url.contains("@") || url.contains(":")
    }

    private static func utf16ToScalarOffset(_ string: NSString, _ location: Int) -> Int {
        guard location > 0 else { return 0 }
        return (string.substring(to: location) as String).unicodeScalars.count
    }

    private static func writeDestination(_ url: String) -> String {
        var opens = 0
        var balanced = true
        for ch in url {
            if ch == "(" { opens += 1 }
            if ch == ")" { opens -= 1; if opens < 0 { balanced = false } }
        }
        if url.contains(" ") || url.contains("<") || !balanced || opens != 0 {
            return "<\(url.replacingOccurrences(of: ">", with: "%3E"))>"
        }
        return url
    }

    private static func codeSpan(_ content: String) -> String {
        var longest = 0
        var run = 0
        for ch in content {
            if ch == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = content.hasPrefix("`") || content.hasSuffix("`")
            || (content.count >= 2 && content.hasPrefix(" ") && content.hasSuffix(" ") && content.contains(where: { $0 != " " }))
        return pad ? "\(fence) \(content) \(fence)" : "\(fence)\(content)\(fence)"
    }

    /// Moves whitespace at the edges of bold, italic and strikethrough spans
    /// outside them, where Markdown needs it.
    private static func trimmingFormatWhitespace(_ text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let string = text.string as NSString
        let full = NSRange(location: 0, length: text.length)
        for key in [NSAttributedString.Key.lotionBold, .lotionItalic, .lotionStrike] {
            var spans: [NSRange] = []
            result.enumerateAttribute(key, in: full) { value, range, _ in
                if value != nil {
                    if let last = spans.last, NSMaxRange(last) == range.location {
                        spans[spans.count - 1] = NSUnionRange(last, range)
                    } else {
                        spans.append(range)
                    }
                }
            }
            for span in spans {
                var start = span.location
                var end = NSMaxRange(span)
                while start < end, isSpace(string.character(at: start)) { start += 1 }
                while end > start, isSpace(string.character(at: end - 1)) { end -= 1 }
                if start > span.location { result.removeAttribute(key, range: NSRange(location: span.location, length: start - span.location)) }
                if end < NSMaxRange(span) { result.removeAttribute(key, range: NSRange(location: end, length: NSMaxRange(span) - end)) }
            }
        }
        return result
    }

    private static func isSpace(_ unit: unichar) -> Bool { unit == 32 || unit == 10 || unit == 9 }

    /// Escapes what would otherwise read as Markdown. `context` is the whole
    /// text the piece sits in, so delimiters are judged by their neighbours.
    static func escape(_ piece: String, context: [Unicode.Scalar], offset: Int) -> String {
        guard piece.unicodeScalars.contains(where: { "\\*_~`[<#->+=.)|0123456789".unicodeScalars.contains($0) }) else { return piece }
        var out = String.UnicodeScalarView()
        var g = offset
        for ch in piece.unicodeScalars {
            let previous: Unicode.Scalar = g > 0 ? context[g - 1] : "\n"
            let next: Unicode.Scalar = g + 1 < context.count ? context[g + 1] : "\n"
            let lineStart = previous == "\n"
            var needs = false
            switch ch {
            case "\\":
                needs = isASCIIPunctuation(next) || next == "\n"
            case "*", "_":
                var start = g
                while start > 0, context[start - 1] == ch { start -= 1 }
                var end = g + 1
                while end < context.count, context[end] == ch { end += 1 }
                let before: Unicode.Scalar = start > 0 ? context[start - 1] : "\n"
                let after: Unicode.Scalar = end < context.count ? context[end] : "\n"
                let (open, close) = flanking(ch, before: before, after: after)
                needs = open || close || (lineStart && ch == "*" && (next == " " || next == "*"))
                    || (lineStart && ch == "_" && next == "_")
            case "~":
                needs = previous == "~" || next == "~"
            case "`":
                needs = true
            case "[":
                needs = context[(g + 1)...].contains("]")
            case "<":
                needs = next.properties.isAlphabetic || next == "/" || next == "!" || next == "?"
            case "#":
                if lineStart {
                    var k = g
                    while k < context.count, context[k] == "#" { k += 1 }
                    needs = k - g <= 6 && (k == context.count || context[k] == " " || context[k] == "\n")
                }
            case "-", "+":
                needs = lineStart && (next == " " || next == "\n" || (ch == "-" && next == "-"))
            case ">":
                needs = lineStart
            case "=":
                if lineStart {
                    var k = g
                    while k < context.count, context[k] == "=" { k += 1 }
                    needs = k == context.count || context[k] == "\n"
                }
            case ".", ")":
                // `1. ` at a line's start would start a numbered list.
                if next == " " || next == "\n" || g + 1 == context.count {
                    var k = g - 1
                    while k >= 0, context[k].properties.numericType != nil, context[k].isASCII { k -= 1 }
                    needs = k < g - 1 && (k < 0 || context[k] == "\n")
                }
            default:
                break
            }
            if needs { out.append("\\") }
            out.append(ch)
            g += 1
        }
        return String(out)
    }
}
