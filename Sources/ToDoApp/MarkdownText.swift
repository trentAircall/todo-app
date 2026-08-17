import SwiftUI
import Foundation

/// Renders a task's description body as markdown so `[label](url)` links —
/// and bare `https://…` URLs, which get auto-wrapped first — are clickable.
/// This is how "presentation links etc." in a meeting's notes end up
/// tappable without a dedicated links schema.
struct MarkdownText: View {
    let text: String

    var body: some View {
        Text(Self.attributed(for: text))
            .textSelection(.enabled)
    }

    static func attributed(for text: String) -> AttributedString {
        let prepared = autolinkPlainURLs(demoteBlockSyntax(text))
        var options = AttributedString.MarkdownParsingOptions()
        // `.inlineOnlyPreservingWhitespace` keeps the author's line breaks,
        // which matters for notes. The trade-off is that block constructs
        // are NOT interpreted — hence `demoteBlockSyntax` below. Switching
        // to `.full` is not the fix: it emits block presentation intents
        // that `Text` ignores, so headings and bullets would lose their
        // line structure entirely instead of just their styling.
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: prepared, options: options) {
            return attributed
        }
        return AttributedString(text)
    }

    /// Rewrites the block-level markdown we actually generate into inline
    /// equivalents, so it stops rendering as literal `##` and `*` noise.
    ///
    /// The MCP server's `log_enrichment` writes an `## Enrichment log`
    /// heading followed by `- ` bullets; hand-written prep notes use the
    /// same shapes. Headings become bold text, and list markers become a
    /// real bullet character.
    static func demoteBlockSyntax(_ text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { line -> String in
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                let content = line[line.index(line.startIndex, offsetBy: indent.count)...]

                if let hashes = content.range(of: "^#{1,6}[ \t]+", options: .regularExpression) {
                    let title = content[hashes.upperBound...].trimmingCharacters(in: .whitespaces)
                    return title.isEmpty ? String(line) : "\(indent)**\(title)**"
                }
                if let marker = content.range(of: "^[-*+][ \t]+", options: .regularExpression) {
                    return "\(indent)•  \(content[marker.upperBound...])"
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// Wraps bare URLs in markdown link syntax so they render clickable too,
    /// without double-wrapping URLs that are already inside `[label](url)`.
    static func autolinkPlainURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s\)\]]+"#) else { return text }
        let ns = text as NSString
        var result = ""
        var lastIndex = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            result += ns.substring(with: NSRange(location: lastIndex, length: range.location - lastIndex))
            lastIndex = range.location + range.length

            // Only skip a URL that's already the target of a markdown link —
            // i.e. preceded by "](", not by any old "(". Checking for a bare
            // paren meant "Zoom (https://zoom.us/j/1)" — a very common shape
            // in pasted calendar invites — rendered as dead plain text.
            let alreadyLinked = range.location >= 2
                && ns.substring(with: NSRange(location: range.location - 2, length: 2)) == "]("
            if alreadyLinked {
                result += ns.substring(with: range)
                continue
            }

            // Sentence punctuation isn't part of the URL. "See https://x.com."
            // used to link to "https://x.com." including the full stop.
            var urlString = ns.substring(with: range)
            var trailing = ""
            while let last = urlString.last, ".,;:!?".contains(last) {
                trailing.insert(last, at: trailing.startIndex)
                urlString.removeLast()
            }
            if urlString.isEmpty {
                result += trailing
                continue
            }
            result += "[\(urlString)](\(urlString))" + trailing
        }
        result += ns.substring(with: NSRange(location: lastIndex, length: ns.length - lastIndex))
        return result
    }
}
