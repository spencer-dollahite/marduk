import Foundation

/// RSS article bodies arrive as HTML in newsboat's cache. Marduk never
/// renders — it reads aloud — so this strips markup down to plain text
/// shaped for the reading machinery: block boundaries become newlines
/// (j/k walk them) and paragraph breaks become BLANK lines, which is
/// exactly what ReadNavigator's {/} paragraph motions key on. Pure string
/// work, unit-tested; anything that fails to parse degrades to "strip the
/// angle brackets", never to silence.
enum NewsHTML {

    /// Tags whose CONTENT is noise, not prose.
    private static let dropContent = try! NSRegularExpression(
        pattern: "<(script|style|head|noscript|template)\\b[^>]*>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// An img contributes its alt text (the only prose an image has).
    private static let imgAlt = try! NSRegularExpression(
        pattern: "<img\\b[^>]*\\balt=(\"([^\"]*)\"|'([^']*)')[^>]*>",
        options: [.caseInsensitive])

    /// Block CLOSERS that end a paragraph-shaped unit → blank line.
    private static let paragraphBreaks = try! NSRegularExpression(
        pattern: "</(p|div|h[1-6]|blockquote|ul|ol|table|figure|section|article|pre)>",
        options: [.caseInsensitive])

    /// Line-shaped breaks → single newline.
    private static let lineBreaks = try! NSRegularExpression(
        pattern: "<br\\s*/?>|</(li|tr|dt|dd)>",
        options: [.caseInsensitive])

    /// Whatever tags remain vanish.
    private static let anyTag = try! NSRegularExpression(
        pattern: "<[^>]+>", options: [])

    static func text(from html: String) -> String {
        var s = html
        s = replace(dropContent, in: s, with: " ")
        s = replaceImgAlt(in: s)
        s = replace(paragraphBreaks, in: s, with: "\n\n")
        s = replace(lineBreaks, in: s, with: "\n")
        s = replace(anyTag, in: s, with: " ")
        s = decodeEntities(s)
        return normalize(s)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String,
                                with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template)
    }

    private static func replaceImgAlt(in text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in imgAlt.matches(in: text,
                                    range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: match.range.location - cursor))
            let alt = match.range(at: 2).location != NSNotFound
                ? ns.substring(with: match.range(at: 2))
                : ns.substring(with: match.range(at: 3))
            if !alt.isEmpty { result += " \(alt) " }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// The handful of named entities feeds actually use, plus every
    /// numeric form. Unknown named entities stay literal — reading
    /// "&weird;" aloud beats guessing.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "mdash": "\u{2014}", "ndash": "\u{2013}",
        "hellip": "\u{2026}", "rsquo": "\u{2019}", "lsquo": "\u{2018}",
        "rdquo": "\u{201D}", "ldquo": "\u{201C}", "copy": "\u{00A9}",
        "trade": "\u{2122}", "reg": "\u{00AE}", "deg": "\u{00B0}",
        "times": "\u{00D7}", "middot": "\u{00B7}", "bull": "\u{2022}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "eacute": "\u{00E9}",
        "amp;": "&",
    ]

    private static let entity = try! NSRegularExpression(
        pattern: "&(#x?[0-9a-fA-F]+|[a-zA-Z]+);", options: [])

    static func decodeEntities(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in entity.matches(in: text,
                                    range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor,
                                                 length: match.range.location - cursor))
            let body = ns.substring(with: match.range(at: 1))
            if body.hasPrefix("#") {
                let hex = body.lowercased().hasPrefix("#x")
                let digits = String(body.dropFirst(hex ? 2 : 1))
                if let value = UInt32(digits, radix: hex ? 16 : 10),
                   let scalar = Unicode.Scalar(value) {
                    result.append(Character(scalar))
                } else {
                    result += ns.substring(with: match.range)
                }
            } else if let replacement = namedEntities[body.lowercased()] {
                result += replacement
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Collapse runs of spaces/tabs, trim line edges, and cap newline runs
    /// at one blank line — the paragraph shape {/} expects, never a fake
    /// page of vertical whitespace.
    private static func normalize(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line -> String in
                line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun == 1, !result.isEmpty { result.append("") }
            } else {
                blankRun = 0
                result.append(line)
            }
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
