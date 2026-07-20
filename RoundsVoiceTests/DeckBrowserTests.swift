import Foundation
import SwiftData
import Testing
@testable import RoundsVoice

struct ClozeEditorSupportTests {
    @Test func nextClozeNumberIncrements() {
        #expect(ClozeEditorSupport.nextClozeNumber(in: "plain text") == 1)
        #expect(ClozeEditorSupport.nextClozeNumber(in: "{{c1::foo}} and bar") == 2)
        #expect(ClozeEditorSupport.nextClozeNumber(in: "{{c1::a}} {{c3::b}}") == 4)
    }

    @Test func wrapSelectionCreatesClozeAndVoiceReadsBlank() {
        let text = "Metformin activates AMPK"
        let range = text.range(of: "AMPK")!
        let result = ClozeEditorSupport.wrapSelection(in: text, selection: range)
        #expect(result.text.contains("{{c1::AMPK}}"))
        #expect(ClozeParser.containsCloze(result.text))
        let spoken = ClozeParser.spokenQuestion(from: result.text, clozeNumber: 1)
        #expect(spoken.contains("blank"))
        #expect(!spoken.contains("AMPK"))
    }

    @Test func wrapSelectionDoesNotDoubleWrap() {
        let text = "{{c1::AMPK}}"
        let range = text.startIndex..<text.endIndex
        let result = ClozeEditorSupport.wrapSelection(in: text, selection: range)
        #expect(result.text == text)
    }
}

struct CardQuerySearchTests {
    @Test func parsesSubstringWildcardAndRegex() {
        #expect(CardQuery.SearchMode.parse("") == nil)

        guard case .substring(let sub) = CardQuery.SearchMode.parse("AMPK") else {
            Issue.record("Expected substring")
            return
        }
        #expect(sub == "ampk")
        #expect(CardQuery.SearchMode.parse("AMPK")!.matches("activates ampk pathway"))

        guard case .wildcard = CardQuery.SearchMode.parse("met*ormin") else {
            Issue.record("Expected wildcard")
            return
        }
        #expect(CardQuery.SearchMode.parse("met*ormin")!.matches("metformin"))
        #expect(CardQuery.SearchMode.parse("met*ormin")!.matches("drug metformin pathway"))
        #expect(!CardQuery.SearchMode.parse("met*ormin")!.matches("vancomycin"))

        guard case .regex = CardQuery.SearchMode.parse("re:ampk|metformin") else {
            Issue.record("Expected regex")
            return
        }
        #expect(CardQuery.SearchMode.parse("re:ampk|metformin")!.matches("use of metformin"))
    }
}

@MainActor
struct DeckManagementTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Deck.self, Card.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test func createDeckAddCardMoveAndBatchSuspend() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()

        guard let deckA = vm.createDeck(name: "Deck A", context: context),
              let deckB = vm.createDeck(name: "Deck B", context: context)
        else {
            Issue.record("Failed to create decks")
            return
        }

        let cards = vm.addCard(
            to: deckA,
            front: "What activates {{c1::AMPK}}?",
            back: "",
            tags: ["endo"],
            context: context
        )
        #expect(!cards.isEmpty)
        #expect(deckA.cardCount >= 1)
        #expect(cards.allSatisfy { $0.cardType == .cloze })
        #expect(cards.first?.spokenQuestion.contains("blank") == true)

        let basic = vm.addCard(
            to: deckA,
            front: "What is metformin?",
            back: "Biguanide",
            context: context
        )
        #expect(basic.count == 1)

        let beforeA = deckA.cardCount
        let beforeB = deckB.cardCount
        vm.moveCards(basic, to: deckB, context: context)
        #expect(basic.first?.deck?.id == deckB.id)
        #expect(deckA.cardCount == beforeA - 1)
        #expect(deckB.cardCount == beforeB + 1)

        vm.setSuspended(cards: cards, suspended: true, context: context)
        #expect(cards.allSatisfy { $0.isSuspended })

        let page = try CardQuery.fetchPage(
            deckID: deckA.id,
            filter: .suspended,
            search: "ampk",
            offset: 0,
            limit: 20,
            context: context
        )
        #expect(page.totalMatching >= 1)
        #expect(page.cards.contains(where: { $0.id == cards[0].id }))

        vm.deleteCards(cards, context: context)
        let remaining = try CardQuery.fetchPage(
            deckID: deckA.id,
            filter: .all,
            search: "",
            offset: 0,
            limit: 50,
            context: context
        )
        #expect(!remaining.cards.contains(where: { cards.map(\.id).contains($0.id) }))
    }

    @Test func multiSelectStyleFetchByIDs() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()
        guard let deck = vm.createDeck(name: "Fetch", context: context) else {
            Issue.record("no deck")
            return
        }
        let created = vm.addCard(to: deck, front: "Alpha", back: "1", context: context)
            + vm.addCard(to: deck, front: "Beta", back: "2", context: context)
        let ids = Set(created.map(\.id))
        let fetched = try CardQuery.fetchCards(ids: ids, context: context)
        #expect(fetched.count == created.count)
    }

    @Test func fetchMatchingIDsEqualsTotalAndBatchSuspendReachesUnloaded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()
        guard let deck = vm.createDeck(name: "SelectAll", context: context) else {
            Issue.record("no deck")
            return
        }

        var created: [Card] = []
        for i in 0..<12 {
            created += vm.addCard(
                to: deck,
                front: "Card \(i) unique-\(i)",
                back: "A",
                tags: i < 8 ? ["batch"] : ["other"],
                context: context
            )
        }

        let filter = StudyFilter(tags: ["batch"], matchMode: .and)
        let page = try CardQuery.fetchPage(
            deckID: deck.id,
            filter: .all,
            search: "",
            offset: 0,
            limit: 3,
            context: context,
            studyFilter: filter
        )
        #expect(page.totalMatching == 8)
        #expect(page.cards.count == 3)

        let matchingIDs = try CardQuery.fetchMatchingIDs(
            deckID: deck.id,
            filter: .all,
            search: "",
            context: context,
            studyFilter: filter
        )
        #expect(matchingIDs.count == page.totalMatching)

        let selected = try CardQuery.fetchCards(
            ids: Set(matchingIDs),
            context: context,
            deckID: deck.id
        )
        #expect(selected.count == 8)
        vm.setSuspended(cards: selected, suspended: true, context: context)

        let suspendedPage = try CardQuery.fetchPage(
            deckID: deck.id,
            filter: .suspended,
            search: "",
            offset: 0,
            limit: 50,
            context: context,
            studyFilter: filter
        )
        #expect(suspendedPage.totalMatching == 8)
        #expect(selected.allSatisfy { $0.isSuspended })
    }
}
