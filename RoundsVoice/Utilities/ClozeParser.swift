import Foundation

/// Parses Anki cloze deletion markup into voice-friendly Q&A.
///
/// Supports:
/// - `{{c1::answer}}` / `{{c1::answer::hint}}`
/// - Multi-cloze `c1`/`c2`/…
/// - AnKing sequential / one-by-one (multiple blanks, often sharing `c1`)
enum ClozeParser {
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
        question(from: text, clozeNumber: clozeNumber, style: .spoken)
    }

    /// On-screen cloze (Anki-style `[...]`), not the spoken word “blank”.
    static func displayQuestion(from text: String, clozeNumber: Int) -> String {
        question(from: text, clozeNumber: clozeNumber, style: .display)
    }

    private enum BlankStyle {
        case spoken
        case display
    }

    private static func question(from text: String, clozeNumber: Int, style: BlankStyle) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let withBlanks = cleaned.replacing(clozePattern) { match in
            let number = Int(match.output.1) ?? 0
            let answer = String(match.output.2)
            let hint = match.output.3.map(String.init)
            if number == clozeNumber {
                return blankToken(hint: hint, style: style)
            }
            return answer
        }
        return normalizeSpoken(withBlanks)
    }

    private static func blankToken(hint: String?, style: BlankStyle) -> String {
        switch style {
        case .spoken:
            // Never speak the hint — AnKing often puts the answer (or a giveaway like "B6")
            // in the hint slot. Screen can still show [hint]; ears only hear "blank".
            _ = hint
            return "blank"
        case .display:
            if let hint, !hint.isEmpty { return "[\(hint)]" }
            return "[...]"
        }
    }

    static func spokenAnswer(from text: String, clozeNumber: Int) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        return deletions(in: cleaned)
            .filter { $0.number == clozeNumber }
            .map { normalizeSpoken($0.answer) }
            .joined(separator: "; ")
    }

    /// Reveal prior deletions; blank the active one; hide later ones as ellipsis.
    static func spokenQuestionSequential(from text: String, activeOrdinal: Int) -> String {
        questionSequential(from: text, activeOrdinal: activeOrdinal, style: .spoken)
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
            return style == .display ? "[...]" : "…"
        }
        return normalizeSpoken(withBlanks)
    }

    static func spokenAnswerSequential(from text: String, activeOrdinal: Int) -> String {
        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: text)
        let items = deletions(in: cleaned)
        guard activeOrdinal >= 0, activeOrdinal < items.count else { return "" }
        return normalizeSpoken(items[activeOrdinal].answer)
    }

    /// - Standard: one card per unique `cN` (Anki default)
    /// - Sequential: one card per deletion when one-by-one is on, or multiple blanks share a `cN`
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

        let sequence = oneByOne || hasSharedClozeNumbers(items)

        if sequence {
            return items.indices.map { ordinal in
                var cardTags = tags
                if oneByOne {
                    cardTags.append("anking:one-by-one")
                } else {
                    cardTags.append("anking:sequential")
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

        let numbers = Array(Set(items.map(\.number))).sorted()
        return numbers.map { number in
            Card(
                front: cleaned,
                back: back.isEmpty ? spokenAnswer(from: cleaned, clozeNumber: number) : back,
                tags: tags,
                deckName: deckName,
                cardType: .cloze,
                clozeNumber: number,
                ankiNoteId: ankiNoteId
            )
        }
    }

    private static func hasSharedClozeNumbers(_ items: [Deletion]) -> Bool {
        Dictionary(grouping: items, by: \.number).values.contains { $0.count > 1 }
    }

    private static func normalizeSpoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
