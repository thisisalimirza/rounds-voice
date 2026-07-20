import Foundation
import SwiftData
import Testing
@testable import RoundsVoice

struct VoiceScriptBaselineTests {
    @Test func polishStripsChromeAndExpandsCommonAbbrevs() {
        let raw = "AMPK → *B6* deficiency vs. CO2 retention"
        let polished = VoiceScriptBaseline.polishForSpeech(raw)
        #expect(!polished.contains("→"))
        #expect(!polished.contains("*"))
        #expect(polished.localizedCaseInsensitiveContains("versus") || polished.localizedCaseInsensitiveContains("vs"))
        #expect(polished.localizedCaseInsensitiveContains("B six") || polished.localizedCaseInsensitiveContains("b six"))
    }

    @Test func contentHashChangesWhenFrontChanges() {
        let a = VoiceScriptBaseline.contentHash(
            front: "{{c1::Metformin}} activates AMPK",
            back: "",
            clozeNumber: 1,
            clozeOrdinal: 0
        )
        let b = VoiceScriptBaseline.contentHash(
            front: "{{c1::Insulin}} activates AMPK",
            back: "",
            clozeNumber: 1,
            clozeOrdinal: 0
        )
        #expect(a != b)
        #expect(a.count == 64)
    }
}

struct VoiceScriptParseTests {
    @Test func parseResponseReadsJSONObject() {
        let raw = #"{"prompt":"What activates blank?","answer":"AMPK"}"#
        let parsed = VoiceScriptService.parseResponse(raw)
        #expect(parsed?.prompt == "What activates blank?")
        #expect(parsed?.answer == "AMPK")
    }

    @Test func parseResponseAcceptsFencedJSON() {
        let raw = """
        ```json
        {"prompt":"Drug that causes blank deficiency","answer":"Isoniazid"}
        ```
        """
        let parsed = VoiceScriptService.parseResponse(raw)
        #expect(parsed?.prompt.contains("blank") == true)
        #expect(parsed?.answer == "Isoniazid")
    }

    @Test func parseResponseRejectsEmpty() {
        #expect(VoiceScriptService.parseResponse("{}") == nil)
        #expect(VoiceScriptService.parseResponse("not json") == nil)
    }
}

@MainActor
struct VoiceScriptCardTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Deck.self, Card.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func initAppliesBaselineVoiceScript() throws {
        let card = Card(
            front: "{{c1::Vancomycin}} binds D-Ala-D-Ala",
            back: "",
            deckName: "t",
            cardType: .cloze,
            clozeNumber: 1
        )
        #expect(!card.voicePrompt.isEmpty)
        #expect(!card.voiceAnswer.isEmpty)
        #expect(card.voiceScriptSource == VoiceScriptSource.baseline.rawValue)
        #expect(card.voiceScriptHash == VoiceScriptBaseline.contentHash(for: card))
        #expect(card.effectiveVoicePrompt.localizedCaseInsensitiveContains("blank"))
        #expect(card.effectiveVoiceAnswer.localizedCaseInsensitiveContains("Vancomycin"))
    }

    @Test func editInvalidatesAndRebuildsBaseline() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()
        guard let deck = vm.createDeck(name: "Voice", context: context) else {
            Issue.record("deck")
            return
        }
        let cards = vm.addCard(
            to: deck,
            front: "{{c1::Metformin}} activates AMPK",
            back: "",
            context: context
        )
        guard let card = cards.first else {
            Issue.record("card")
            return
        }
        let oldHash = card.voiceScriptHash
        card.voiceScriptSource = VoiceScriptSource.llm.rawValue
        card.voicePrompt = "Polished prompt with blank"
        card.voiceAnswer = "Metformin"

        vm.saveCardEdits(
            card,
            front: "{{c1::Insulin}} activates AMPK",
            back: "",
            tags: [],
            context: context
        )
        #expect(card.voiceScriptSource == VoiceScriptSource.baseline.rawValue)
        #expect(card.voiceScriptHash != oldHash)
        #expect(card.effectiveVoiceAnswer.localizedCaseInsensitiveContains("Insulin"))
    }

    @Test func ensureFreshBackfillsEmptyVoiceFields() {
        let card = Card(front: "What is AMPK?", back: "Kinase", deckName: "t")
        card.voicePrompt = ""
        card.voiceAnswer = ""
        card.voiceScriptHash = ""
        card.ensureVoiceScriptReady()
        #expect(!card.effectiveVoicePrompt.isEmpty)
        #expect(card.effectiveVoiceAnswer == "Kinase" || card.voiceAnswer.contains("Kinase"))
    }
}
