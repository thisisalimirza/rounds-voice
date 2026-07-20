import Foundation

/// Parses Anki cloze deletion markup into voice-friendly Q&A.
///
/// Voice rule: **one graded blank per card**. Multi-blank notes always expand
/// to one card per deletion so TTS/grading stay unambiguous.
enum ClozeParser {
    /// Non-greedy body; allows nested `::hint`.
    private static let clozePattern = /\{\{c(\d+)::(.*?)(?:::(.*?))?\}\}/

    struct Deletion: Equatable, Sendable {
        var number: Int
        var ordinal: Int
        var answer: String
        var hint: String?
    }

    static func containsCloze(_ text: String) -> Bool {
        text.contains(clozePattern)
    }

    static func deletions(in text: String) -> [Deletion] {
        text.matches(of: clozePattern).enumerated().compactMap { index, match in
            guard let number = Int(match.output.1) else { return nil }
            return Deletion(
                number: number,
                ordinal: index,
                answer: String(match.output.2),
                hint: match.output.3.map(String.init)
            )
        }
    }

    static func clozeNumbers(in text: String) -> [Int] {
        Array(Set(deletions(in: text).map(\.number))).sorted()
    }

    static func spokenQuestion(from text: String, clozeNumber: Int) -> String {
        // If this number blanks more than one slot, force one-at-a-time (first match).
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let matches = deletions(in: cleaned).filter { $0.number == clozeNumber }
        if matches.count > 1 {
            return spokenQuestionSequential(from: cleaned, activeOrdinal: matches[0].ordinal)
        }
        return sanitizeSpoken(question(from: cleaned, clozeNumber: clozeNumber, style: .spoken))
    }

    /// On-screen cloze (Anki-style `[...]` blanks — never the word “blank”).
    static func displayQuestion(from text: String, clozeNumber: Int) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let matches = deletions(in: cleaned).filter { $0.number == clozeNumber }
        if matches.count > 1 {
            return displayQuestionSequential(from: cleaned, activeOrdinal: matches[0].ordinal)
        }
        return question(from: cleaned, clozeNumber: clozeNumber, style: .display)
    }

    private enum BlankStyle {
        case spoken
        case display
    }

    private static func question(from text: String, clozeNumber: Int, style: BlankStyle) -> String {
        let withBlanks = text.replacing(clozePattern) { match in
            let number = Int(match.output.1) ?? 0
            let answer = String(match.output.2)
            let hint = match.output.3.map(String.init)
            if number == clozeNumber {
                return blankToken(hint: hint, style: style)
            }
            // Other cloze numbers: reveal the answer (standard Anki).
            return answer
        }
        return normalizeWhitespace(withBlanks)
    }

    private static func blankToken(hint: String?, style: BlankStyle) -> String {
        switch style {
        case .spoken:
            // Never speak the hint — AnKing often puts the answer in the hint slot.
            _ = hint
            return "blank"
        case .display:
            if let hint, !hint.isEmpty { return "[\(hint)]" }
            return "[...]"
        }
    }

    static func spokenAnswer(from text: String, clozeNumber: Int) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let matches = deletions(in: cleaned).filter { $0.number == clozeNumber }
        // One graded answer — if shared cN slipped through, take the first only.
        guard let first = matches.first else { return "" }
        return normalizeWhitespace(first.answer)
    }

    /// Reveal prior deletions; blank only the active one; soften later ones.
    static func spokenQuestionSequential(from text: String, activeOrdinal: Int) -> String {
        sanitizeSpoken(questionSequential(from: text, activeOrdinal: activeOrdinal, style: .spoken))
    }

    static func displayQuestionSequential(from text: String, activeOrdinal: Int) -> String {
        questionSequential(from: text, activeOrdinal: activeOrdinal, style: .display)
    }

    private static func questionSequential(from text: String, activeOrdinal: Int, style: BlankStyle) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        var ordinal = 0
        let withBlanks = cleaned.replacing(clozePattern) { match in
            let answer = String(match.output.2)
            let hint = match.output.3.map(String.init)
            let current = ordinal
            ordinal += 1
            if current == activeOrdinal {
                return blankToken(hint: hint, style: style)
            }
            if current < activeOrdinal {
                return answer
            }
            // Future blanks: must NOT look/sound like another graded slot.
            return style == .display ? "⋯" : ""
        }
        return normalizeWhitespace(withBlanks)
    }

    static func spokenAnswerSequential(from text: String, activeOrdinal: Int) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let items = deletions(in: cleaned)
        guard activeOrdinal >= 0, activeOrdinal < items.count else { return "" }
        return normalizeWhitespace(items[activeOrdinal].answer)
    }

    /// Always one voice card per deletion when a note has multiple blanks.
    static func expandToCards(
        noteText: String,
        back: String = "",
        tags: [String],
        deckName: String,
        ankiNoteId: String? = nil,
        oneByOne: Bool = false
    ) -> [Card] {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: noteText)
        let items = deletions(in: cleaned)

        guard !items.isEmpty else {
            return [
                Card(
                    front: noteText,
                    back: back,
                    tags: tags,
                    deckName: deckName,
                    cardType: .basic,
                    ankiNoteId: ankiNoteId
                )
            ]
        }

        // Voice-first: every multi-blank note becomes one graded blank per card.
        if items.count > 1 {
            return items.indices.map { ordinal in
                var cardTags = tags
                if oneByOne {
                    cardTags.append("anking:one-by-one")
                } else if hasSharedClozeNumbers(items) {
                    cardTags.append("anking:sequential")
                } else {
                    cardTags.append("anking:voice-split")
                }
                return Card(
                    front: cleaned,
                    back: back,
                    tags: cardTags,
                    deckName: deckName,
                    cardType: .cloze,
                    clozeNumber: items[ordinal].number,
                    clozeOrdinal: ordinal,
                    ankiNoteId: ankiNoteId.map { "\($0)#\(ordinal)" }
                )
            }
        }

        let only = items[0]
        return [
            Card(
                front: cleaned,
                back: back.isEmpty ? normalizeWhitespace(only.answer) : back,
                tags: tags,
                deckName: deckName,
                cardType: .cloze,
                clozeNumber: only.number,
                clozeOrdinal: 0,
                ankiNoteId: ankiNoteId
            )
        ]
    }

    private static func hasSharedClozeNumbers(_ items: [Deletion]) -> Bool {
        Dictionary(grouping: items, by: \.number).values.contains { $0.count > 1 }
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Last-line defense: never let raw cloze markup or leaked answers-as-markup hit TTS.
    static func sanitizeSpoken(_ text: String) -> String {
        var out = text
        // Any unparsed cloze → blank (do not speak the answer inside).
        out = out.replacing(clozePattern) { _ in "blank" }
        // Stray braces / cN crumbs.
        out = out.replacingOccurrences(of: #"\{\{[^}]*\}\}"#, with: "blank", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"(?i)\bcloze\s*deletions?\b"#,
            with: "blank",
            options: .regularExpression
        )
        // Collapse accidental "blank blank".
        out = out.replacingOccurrences(
            of: #"(?i)\bblank(\s+blank)+\b"#,
            with: "blank",
            options: .regularExpression
        )
        return normalizeWhitespace(out)
    }
}
