import Foundation

/// Strips Anki/HTML markup so cards can be spoken and graded as plain text.
enum AnkiHTMLCleaner {
    static func plainText(from html: String) -> String {
        var text = html

        // Common Anki newlines
        text = text.replacingOccurrences(of: "<br>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br/>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br />", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<div>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<p>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</p>", with: " ", options: .caseInsensitive)

        // Strip remaining tags
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )

        // Decode a few common entities
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Anki media refs like [sound:...] — drop for voice MVP
        text = text.replacingOccurrences(
            of: #"\[sound:[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )

        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
