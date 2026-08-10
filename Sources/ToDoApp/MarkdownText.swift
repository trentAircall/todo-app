import SwiftUI

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
        let linked = autolinkPlainURLs(text)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attributed = try? AttributedString(markdown: linked, options: options) {
            return attributed
        }
        return AttributedString(text)
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
            let urlString = ns.substring(with: range)
            let precededByParen = range.location > 0
                && ns.substring(with: NSRange(location: range.location - 1, length: 1)) == "("
            result += precededByParen ? urlString : "[\(urlString)](\(urlString))"
            lastIndex = range.location + range.length
        }
        result += ns.substring(with: NSRange(location: lastIndex, length: ns.length - lastIndex))
        return result
    }
}
