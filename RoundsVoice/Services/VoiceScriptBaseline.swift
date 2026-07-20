import Foundation
import CryptoKit

/// Cheap deterministic voice scripts for AnKing-scale imports (no network).
enum VoiceScriptBaseline {
    /// Stable identity of the study text that the voice script was built from.
    static func contentHash(
        front: String,
        back: String,
        clozeNumber: Int?,
        clozeOrdinal: Int?
    ) -> String {
        let payload = [
            front,
            back,
            clozeNumber.map(String.init) ?? "",
            clozeOrdinal.map(String.init) ?? ""
        ].joined(separator: "\u{1e}")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func contentHash(for card: Card) -> String {
        contentHash(
            front: card.front,
            back: card.back,
            clozeNumber: card.clozeNumber,
            clozeOrdinal: card.clozeOrdinal
        )
    }

    /// Build prompt/answer from current computed spoken fields + light cleanup.
    static func build(for card: Card) -> (prompt: String, answer: String) {
        (
            polishForSpeech(card.spokenQuestion),
            polishForSpeech(card.spokenAnswer)
        )
    }

    /// Write baseline script onto the card (always `source = baseline`).
    static func apply(to card: Card) {
        let script = build(for: card)
        card.voicePrompt = script.prompt
        card.voiceAnswer = script.answer
        card.voiceScriptSource = VoiceScriptSource.baseline.rawValue
        card.voiceScriptHash = contentHash(for: card)
    }

    /// If missing or stale, regenerate baseline. Leaves fresh LLM scripts alone.
    static func ensureFresh(_ card: Card) {
        let hash = contentHash(for: card)
        let hasPrompt = !card.voicePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAnswer = !card.voiceAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasPrompt, hasAnswer, card.voiceScriptHash == hash {
            return
        }
        apply(to: card)
    }

    /// True when an LLM polish would improve a baseline (or empty) script.
    static func needsLLMPolish(_ card: Card) -> Bool {
        ensureFresh(card)
        return card.voiceScriptSource != VoiceScriptSource.llm.rawValue
    }

    // MARK: - Speech cleanup

    static func polishForSpeech(_ raw: String) -> String {
        var text = ClozeParser.sanitizeSpoken(raw)

        let replacements: [(String, String)] = [
            ("→", " to "),
            ("↔", " and "),
            ("⇒", " leads to "),
            ("±", " plus or minus "),
            ("≥", " greater than or equal to "),
            ("≤", " less than or equal to "),
            ("↑", " increased "),
            ("↓", " decreased "),
            ("•", ", "),
            ("·", ", "),
            ("*", " "),
            ("\t", " ")
        ]
        for (from, to) in replacements {
            text = text.replacingOccurrences(of: from, with: to)
        }

        // Common AnKing / med abbreviation pronunciation hints.
        let abbrev: [(String, String)] = [
            (#"\bB6\b"#, "B six"),
            (#"\bB12\b"#, "B twelve"),
            (#"\bCO2\b"#, "C O 2"),
            (#"\bO2\b"#, "O 2"),
            (#"\bNa\+\b"#, "sodium"),
            (#"\bK\+\b"#, "potassium"),
            (#"\bCa2\+\b"#, "calcium"),
            (#"\bvs\.?\b"#, "versus"),
            (#"\be\.g\.?\b"#, "for example"),
            (#"\bi\.e\.?\b"#, "that is")
        ]
        for (pattern, replacement) in abbrev {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                text = regex.stringByReplacingMatches(
                    in: text,
                    options: [],
                    range: range,
                    withTemplate: replacement
                )
            }
        }

        // Numbered list crumbs: "1) foo 2) bar" → "first, foo; second, bar" (light touch).
        if let regex = try? NSRegularExpression(pattern: #"\b(\d+)\)\s*"#) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: "; "
            )
        }

        text = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Trim trailing punctuation clutter except ? . !
        while let last = text.last, ",;:".contains(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
