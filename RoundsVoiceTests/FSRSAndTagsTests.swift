import Foundation
import SwiftData
import Testing
@testable import RoundsVoice

struct SiblingBurialTests {
    @Test func noteKeyStripsOrdinalSuffix() {
        let card = Card(
            front: "{{c1::a}}",
            back: "",
            deckName: "t",
            cardType: .cloze,
            clozeNumber: 1,
            clozeOrdinal: 0,
            ankiNoteId: "12345#0"
        )
        #expect(card.siblingKey == "12345")
        #expect(SiblingBurial.noteKey(for: card) == "12345")
    }

    @Test func queueKeepsOneSiblingPerNote() {
        let a1 = Card(front: "a", back: "", deckName: "t", clozeNumber: 1, ankiNoteId: "n1")
        let a2 = Card(front: "a", back: "", deckName: "t", clozeNumber: 2, ankiNoteId: "n1")
        let b1 = Card(front: "b", back: "", deckName: "t", clozeNumber: 1, ankiNoteId: "n2")
        let filtered = SiblingBurial.filterQueueRemovingSiblingDuplicates([a1, a2, b1])
        #expect(filtered.count == 2)
        #expect(filtered.map(\.id).contains(a1.id))
        #expect(!filtered.map(\.id).contains(a2.id))
        #expect(filtered.map(\.id).contains(b1.id))
    }
}

struct ReviewRatingTimingTests {
    @Test func incorrectIsAlwaysAgain() {
        let grade = GradeResult(isCorrect: false, confidence: 0.9, feedback: "No")
        #expect(ReviewRating(from: grade, responseLatency: 0.5) == .again)
        #expect(ReviewRating(from: grade, responseLatency: 20) == .again)
    }

    @Test func fastCorrectIsEasy() {
        let grade = GradeResult(isCorrect: true, confidence: 0.8, feedback: "Yes")
        #expect(ReviewRating(from: grade, responseLatency: 1.2) == .easy)
    }

    @Test func slowCorrectIsHard() {
        let grade = GradeResult(isCorrect: true, confidence: 0.8, feedback: "Yes")
        #expect(ReviewRating(from: grade, responseLatency: 16) == .hard)
    }

    @Test func normalCorrectIsGood() {
        let grade = GradeResult(isCorrect: true, confidence: 0.8, feedback: "Yes")
        #expect(ReviewRating(from: grade, responseLatency: 5) == .good)
        #expect(ReviewRating(from: grade, responseLatency: nil) == .good)
    }
}

struct TagCatalogFilterTests {
    @Test func filterTagsIsInMemoryAndCaseInsensitive() {
        let catalog = [
            TagCount(tag: "#AK_Step1_v12", count: 100),
            TagCount(tag: "Cardio", count: 40),
            TagCount(tag: "Neuro", count: 20)
        ]
        let filtered = TagQuery.filterTags(catalog, matching: "card")
        #expect(filtered.map(\.tag) == ["Cardio"])
        #expect(TagQuery.filterTags(catalog, matching: "").count == 3)
    }

    @Test func buildTreeCreatesHierarchyAndRollsUpCounts() {
        let catalog = [
            TagCount(tag: "A::B::C", count: 3),
            TagCount(tag: "A::B", count: 5),
            TagCount(tag: "A::D", count: 2),
            TagCount(tag: "Z", count: 1)
        ]
        let tree = TagQuery.buildTree(from: catalog)
        #expect(tree.map(\.name) == ["A", "Z"])

        let a = tree.first { $0.name == "A" }
        #expect(a?.count == 10) // 3 + 5 + 2
        let b = a?.children.first { $0.name == "B" }
        #expect(b?.count == 8) // 5 + 3
        #expect(b?.children.map(\.name) == ["C"])
        #expect(b?.children.first?.count == 3)
        #expect(a?.children.first { $0.name == "D" }?.count == 2)
    }

    @Test func tagMatchesPathSupportsPrefixSelection() {
        #expect(TagQuery.tagMatchesPath("A::B::C", selectedPath: "A::B"))
        #expect(TagQuery.tagMatchesPath("A::B", selectedPath: "A::B"))
        #expect(!TagQuery.tagMatchesPath("A::BExtra", selectedPath: "A::B"))
        #expect(!TagQuery.tagMatchesPath("A::C", selectedPath: "A::B"))
    }

    @Test func tagsBlobMatchesExactAndPrefix() {
        let blob = Card.makeTagsBlob(["Shelf::FM::no_dupes", "other"])
        #expect(TagQuery.tagsBlobMatchesPath(blob, path: "Shelf::FM"))
        #expect(TagQuery.tagsBlobMatchesPath(blob, path: "Shelf::FM::no_dupes"))
        #expect(!TagQuery.tagsBlobMatchesPath(blob, path: "Shelf::IM"))
        #expect(TagQuery.tagsBlobMatchesFilter(
            blob,
            filter: StudyFilter(tags: ["Shelf::FM"], matchMode: .and)
        ))
    }
}

@MainActor
struct TagFilterTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Deck.self, Card.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func multiSelectAndOrFiltering() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()
        guard let deck = vm.createDeck(name: "Tagged", context: context) else {
            Issue.record("deck")
            return
        }

        _ = vm.addCard(to: deck, front: "Cardio A", back: "1", tags: ["#AK_Step1_v12", "Cardio"], context: context)
        _ = vm.addCard(to: deck, front: "Cardio B", back: "2", tags: ["#AK_Step1_v12", "Cardio", "Pharm"], context: context)
        _ = vm.addCard(to: deck, front: "Neuro", back: "3", tags: ["#AK_Step1_v12", "Neuro"], context: context)

        let tags = try TagQuery.aggregateTags(deckID: deck.id, context: context)
        #expect(tags.contains(where: { $0.tag == "Cardio" && $0.count == 2 }))

        let andFilter = StudyFilter(tags: ["#AK_Step1_v12", "Cardio"], matchMode: .and)
        let andPage = try CardQuery.fetchPage(
            deckID: deck.id,
            filter: .all,
            search: "",
            offset: 0,
            limit: 20,
            context: context,
            studyFilter: andFilter
        )
        #expect(andPage.totalMatching == 2)

        let orFilter = StudyFilter(tags: ["Cardio", "Neuro"], matchMode: .or)
        let orPage = try CardQuery.fetchPage(
            deckID: deck.id,
            filter: .all,
            search: "",
            offset: 0,
            limit: 20,
            context: context,
            studyFilter: orFilter
        )
        #expect(orPage.totalMatching == 3)

        let andCount = try TagQuery.countMatching(deckID: deck.id, filter: andFilter, context: context)
        #expect(andCount == 2)
    }

    @Test func prefixTagSelectionMatchesChildren() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let vm = DeckListViewModel()
        guard let deck = vm.createDeck(name: "Hierarchy", context: context) else {
            Issue.record("deck")
            return
        }

        let parent = vm.addCard(
            to: deck,
            front: "Parent tag card",
            back: "1",
            tags: ["Shelf::FM"],
            context: context
        )
        let child = vm.addCard(
            to: deck,
            front: "Child tag card",
            back: "2",
            tags: ["Shelf::FM::no_dupes"],
            context: context
        )
        _ = vm.addCard(
            to: deck,
            front: "Other",
            back: "3",
            tags: ["Shelf::IM"],
            context: context
        )

        let filter = StudyFilter(tags: ["Shelf::FM"], matchMode: .or)
        let page = try CardQuery.fetchPage(
            deckID: deck.id,
            filter: .all,
            search: "",
            offset: 0,
            limit: 20,
            context: context,
            studyFilter: filter
        )
        #expect(page.totalMatching == 2)
        let ids = Set(page.cards.map(\.id))
        #expect(ids.contains(parent[0].id))
        #expect(ids.contains(child[0].id))
    }
}

@MainActor
struct FSRSSchedulerTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Deck.self, Card.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func goodReviewIncreasesIntervalAndStability() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deck = Deck(name: "FSRS", source: .manual)
        context.insert(deck)
        let card = Card(front: "Q", back: "A", deckName: "FSRS", deck: deck)
        context.insert(card)
        try context.save()

        let scheduler = FSRSScheduler()
        let before = card.dueDate
        scheduler.recordReview(card: card, rating: .good)

        #expect(card.stability > 0)
        #expect(card.difficulty >= 1 && card.difficulty <= 10)
        #expect(card.interval > 0)
        #expect(card.dueDate > before)
        #expect(card.fsrsState == FSRSState.review.rawValue)
        #expect(card.reps == 1)
    }

    @Test func againSendsToShortRelearn() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deck = Deck(name: "FSRS", source: .manual)
        context.insert(deck)
        let card = Card(front: "Q", back: "A", deckName: "FSRS", deck: deck)
        context.insert(card)
        let scheduler = FSRSScheduler()
        scheduler.recordReview(card: card, rating: .again)
        #expect(card.lapses >= 1)
        #expect(card.interval < 1)
        #expect(card.dueDate > .now)
    }

    @Test func burySiblingsPushesSisterCards() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deck = Deck(name: "Cloze", source: .manual)
        context.insert(deck)
        let c1 = Card(
            front: "{{c1::one}} {{c2::two}}",
            back: "",
            deckName: "Cloze",
            cardType: .cloze,
            clozeNumber: 1,
            ankiNoteId: "note9",
            deck: deck
        )
        let c2 = Card(
            front: "{{c1::one}} {{c2::two}}",
            back: "",
            deckName: "Cloze",
            cardType: .cloze,
            clozeNumber: 2,
            ankiNoteId: "note9",
            deck: deck
        )
        context.insert(c1)
        context.insert(c2)
        DeckStats.noteInserted(card: c1, into: deck)
        DeckStats.noteInserted(card: c2, into: deck)
        try context.save()

        var queue = [c1, c2]
        let buried = SiblingBurial.burySiblings(of: c1, queue: &queue, context: context)
        #expect(buried == 1)
        #expect(queue.count == 1)
        #expect(c2.isBuried)
        #expect(!c2.isDue)
    }
}
