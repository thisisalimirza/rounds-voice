import Foundation
import SwiftData

/// Online LLM polish for voice scripts — only small working sets (never whole AnKing decks).
enum VoiceScriptService {
    private static let systemPrompt = """
    You rewrite Anki/AnKing flashcards into short scripts for spoken review while walking.

    Return JSON only:
    {"prompt":"...","answer":"..."}

    Rules:
    - Keep medical meaning accurate.
    - prompt: one clear spoken question. Use the word "blank" for exactly one missing piece.
    - answer: the short spoken answer only (what the learner should say).
    - No HTML, markdown, braces, or the phrase "cloze deletion".
    - Prefer pronounceable wording (expand awkward symbols; keep standard drug/gene names).
    - Keep prompt under ~40 words when possible; answer under ~15 words when possible.
    - Do not invent facts not supported by the card text.
    """

    struct ParsedScript: Equatable, Sendable {
        var prompt: String
        var answer: String
    }

    /// Parse model JSON into a voice script. Exposed for tests.
    nonisolated static func parseResponse(_ raw: String) -> ParsedScript? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip optional markdown fences.
        var jsonText = trimmed
        if jsonText.hasPrefix("```") {
            jsonText = jsonText
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }

        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let prompt = (obj["prompt"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = (obj["answer"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !prompt.isEmpty, !answer.isEmpty else { return nil }
        return ParsedScript(
            prompt: VoiceScriptBaseline.polishForSpeech(prompt),
            answer: VoiceScriptBaseline.polishForSpeech(answer)
        )
    }

    /// Polish cards that still have baseline scripts. Failures keep baseline.
    @MainActor
    static func polishIfNeeded(
        cards: [Card],
        provider: (any LLMProvider)?,
        context: ModelContext,
        concurrency: Int = 3
    ) async {
        guard let provider else { return }
        let targets = cards.filter { VoiceScriptBaseline.needsLLMPolish($0) }
        guard !targets.isEmpty else { return }

        let limit = max(1, concurrency)
        var index = 0
        while index < targets.count {
            let end = min(index + limit, targets.count)
            let batch = Array(targets[index..<end])
            await withTaskGroup(of: Void.self) { group in
                for card in batch {
                    group.addTask { @MainActor in
                        await polishOne(card, provider: provider)
                    }
                }
            }
            index = end
            try? context.save()
            await Task.yield()
        }
    }

    @MainActor
    private static func polishOne(_ card: Card, provider: any LLMProvider) async {
        VoiceScriptBaseline.ensureFresh(card)
        guard card.voiceScriptSource != VoiceScriptSource.llm.rawValue else { return }

        let userPrompt = """
        Card type: \(card.cardType.rawValue)
        Cloze number: \(card.clozeNumber.map(String.init) ?? "none")
        Cloze ordinal: \(card.clozeOrdinal.map(String.init) ?? "none")

        Anki front:
        \(card.front)

        Anki back / extra:
        \(card.back)

        Current baseline prompt:
        \(card.effectiveVoicePrompt)

        Current baseline answer:
        \(card.effectiveVoiceAnswer)
        """

        let hashBefore = VoiceScriptBaseline.contentHash(for: card)
        do {
            let raw = try await provider.complete(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            guard let parsed = parseResponse(raw) else { return }
            // Ignore stale responses if the card was edited mid-flight.
            guard VoiceScriptBaseline.contentHash(for: card) == hashBefore else { return }
            card.voicePrompt = parsed.prompt
            card.voiceAnswer = parsed.answer
            card.voiceScriptSource = VoiceScriptSource.llm.rawValue
            card.voiceScriptHash = hashBefore
            card.updatedAt = .now
        } catch {
            // Keep baseline — walk must never depend on this succeeding.
        }
    }
}
