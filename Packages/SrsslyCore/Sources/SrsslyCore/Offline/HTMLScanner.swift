import Foundation

/// One start tag found in an HTML document.
public struct HTMLTag: Sendable, Equatable {
    /// Lowercased tag name, e.g. `img`.
    public var name: String
    /// Attributes by lowercased name, with entities decoded. The first
    /// occurrence of a repeated attribute wins, as in browsers.
    public var attributes: [String: String]

    public init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    public subscript(_ attribute: String) -> String? { attributes[attribute] }
}

/// A small, forgiving HTML scanner. It finds start tags and visible text and
/// nothing more: enough to list a page's images without a DOM.
///
/// Real-world feed and page HTML is often broken, so this never fails. It
/// skips comments and the contents of `script` and `style`.
public enum HTMLScanner {
    /// The start tags with the given (lowercase) names, in document order.
    public static func tags(in html: String, named names: Set<String>) -> [HTMLTag] {
        var found: [HTMLTag] = []
        scan(html) { event in
            if case .tag(let tag) = event, names.contains(tag.name) { found.append(tag) }
        }
        return found
    }

    /// Roughly how many visible characters the HTML has, ignoring
    /// whitespace. Used to tell a full post from a one-line summary.
    public static func visibleTextLength(_ html: String) -> Int {
        var count = 0
        scan(html) { event in
            if case .text(let bytes) = event {
                count += bytes.reduce(0) { n, b in
                    // Count characters, not bytes: skip UTF-8 continuation
                    // bytes, and skip whitespace.
                    (b & 0xC0) == 0x80 || isSpace(b) ? n : n + 1
                }
            }
        }
        return count
    }

    // MARK: - Scanning

    private enum Event {
        case tag(HTMLTag)
        case text(ArraySlice<UInt8>)
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
    private static let eq = UInt8(ascii: "="), bang = UInt8(ascii: "!"), dash = UInt8(ascii: "-")
    private static let dquote = UInt8(ascii: "\""), squote = UInt8(ascii: "'"), question = UInt8(ascii: "?")

    private static func scan(_ html: String, _ handle: (Event) -> Void) {
        let b = Array(html.utf8)
        let n = b.count
        var i = 0
        var textStart = 0

        func flushText(upTo end: Int) {
            if end > textStart { handle(.text(b[textStart..<end])) }
        }

        while i < n {
            guard b[i] == lt else { i += 1; continue }
            // Comments, doctypes and processing instructions.
            if i + 1 < n, b[i + 1] == bang || b[i + 1] == question {
                flushText(upTo: i)
                if i + 3 < n, b[i + 2] == dash, b[i + 3] == dash {
                    i = (find([dash, dash, gt], in: b, from: i + 4) ?? n - 3) + 3
                } else {
                    i = (find([gt], in: b, from: i + 2) ?? n - 1) + 1
                }
                textStart = i
                continue
            }
            // End tags.
            if i + 1 < n, b[i + 1] == slash {
                flushText(upTo: i)
                i = (find([gt], in: b, from: i + 2) ?? n - 1) + 1
                textStart = i
                continue
            }
            var j = i + 1
            while j < n, isNameByte(b[j]) { j += 1 }
            guard j > i + 1 else { i += 1; continue } // A stray "<" is text.
            flushText(upTo: i)
            let name = lowercased(b[(i + 1)..<j])

            var attributes: [String: String] = [:]
            while j < n {
                while j < n, isSpace(b[j]) || b[j] == slash { j += 1 }
                guard j < n else { break }
                if b[j] == gt { j += 1; break }
                let nameStart = j
                while j < n, !isSpace(b[j]), b[j] != eq, b[j] != gt, b[j] != slash { j += 1 }
                guard j > nameStart else { j += 1; continue }
                let attribute = lowercased(b[nameStart..<j])
                while j < n, isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == eq {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == dquote || b[j] == squote {
                        let quote = b[j]
                        let end = find([quote], in: b, from: j + 1) ?? n
                        value = String(decoding: b[(j + 1)..<end], as: UTF8.self)
                        j = min(end + 1, n)
                    } else {
                        let start = j
                        while j < n, !isSpace(b[j]), b[j] != gt { j += 1 }
                        value = String(decoding: b[start..<j], as: UTF8.self)
                    }
                }
                if attributes[attribute] == nil { attributes[attribute] = decodeEntities(value) }
            }
            handle(.tag(HTMLTag(name: name, attributes: attributes)))
            i = j

            // Script and style contents are not text or markup.
            if name == "script" || name == "style" {
                let close = Array("</\(name)".utf8)
                i = findCaseInsensitive(close, in: b, from: i) ?? n
            }
            textStart = i
        }
        flushText(upTo: n)
    }

    private static func find(_ needle: [UInt8], in b: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= b.count - needle.count else { return nil }
        var i = start
        while i <= b.count - needle.count {
            if b[i] == needle[0], needle.indices.allSatisfy({ b[i + $0] == needle[$0] }) { return i }
            i += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ needle: [UInt8], in b: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start <= b.count - needle.count else { return nil }
        var i = start
        while i <= b.count - needle.count {
            if needle.indices.allSatisfy({ lower(b[i + $0]) == needle[$0] }) { return i }
            i += 1
        }
        return nil
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }

    private static func isNameByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == dash || c == UInt8(ascii: ":")
    }

    private static func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c + 0x20 : c }

    private static func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map(lower), as: UTF8.self)
    }

    // MARK: - Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
    ]

    /// Decodes the entities that turn up in attribute values: the XML five,
    /// `&nbsp;`, and numeric references.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            guard let semi = rest[afterAmp...].prefix(10).firstIndex(of: ";") else {
                out += "&"
                rest = rest[afterAmp...]
                continue
            }
            let entity = rest[afterAmp..<semi]
            if let decoded = decode(entity) {
                out += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[afterAmp...]
            }
        }
        return out + rest
    }

    private static func decode(_ entity: Substring) -> String? {
        if entity.first == "#" {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
        return named[String(entity)]
    }
}
