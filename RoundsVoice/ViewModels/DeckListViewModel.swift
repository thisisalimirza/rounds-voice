import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class DeckListViewModel {
    private let sampleImporter = SampleDeckImporter()
    private var hasSeeded = false

    var isSeeding = false
    var errorMessage: String?

    /// Seeds sample AnKing decks once on first launch when the store is empty.
    func seedIfNeeded(context: ModelContext) {
        guard !hasSeeded else { return }
        hasSeeded = true

        do {
            var descriptor = FetchDescriptor<Deck>()
            descriptor.fetchLimit = 1
            let existing = try context.fetch(descriptor)
            guard existing.isEmpty else { return }

            isSeeding = true
            defer { isSeeding = false }

            for imported in sampleImporter.loadAllSampleDecks() {
                _ = try DeckPersistence.persist(imported, into: context)
            }
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetSampleDecks(context: ModelContext) {
        do {
            let decks = try context.fetch(FetchDescriptor<Deck>())
            for deck in decks {
                context.delete(deck)
            }
            try context.save()

            hasSeeded = false
            seedIfNeeded(context: context)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createDeck(
        name: String,
        description: String = "",
        context: ModelContext
    ) -> Deck? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let deck = Deck(
                name: trimmed,
                deckDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
                source: .manual
            )
            context.insert(deck)
            try context.save()
            return deck
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func addCard(
        to deck: Deck,
        front: String,
        back: String,
        tags: [String] = [],
        context: ModelContext
    ) -> [Card] {
        let trimmedFront = front.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFront.isEmpty else { return [] }

        do {
            let cards: [Card]
            if ClozeParser.containsCloze(trimmedFront) {
                // Shared note id so sibling bury works for manually authored clozes.
                cards = ClozeParser.expandToCards(
                    noteText: trimmedFront,
                    back: back,
                    tags: tags,
                    deckName: deck.name,
                    ankiNoteId: UUID().uuidString,
                    oneByOne: false
                )
            } else {
                cards = [
                    Card(
                        front: trimmedFront,
                        back: back,
                        tags: tags,
                        deckName: deck.name,
                        cardType: .basic
                    )
                ]
            }

            for card in cards {
                card.deck = deck
                VoiceScriptBaseline.apply(to: card)
                context.insert(card)
                DeckStats.noteInserted(card: card, into: deck)
            }
            deck.updatedAt = .now
            try context.save()
            return cards
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func deleteDeck(_ deck: Deck, context: ModelContext) {
        do {
            context.delete(deck)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameDeck(_ deck: Deck, to name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            deck.name = trimmed
            deck.updatedAt = .now
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteCard(_ card: Card, context: ModelContext) {
        deleteCards([card], context: context)
    }

    func deleteCards(
        _ cards: [Card],
        context: ModelContext,
        updateDeckStats: Bool = true,
        save: Bool = true
    ) {
        guard !cards.isEmpty else { return }
        do {
            for card in cards {
                if updateDeckStats, let deck = card.deck {
                    DeckStats.noteDeleted(card: card, from: deck)
                    deck.updatedAt = .now
                }
                context.delete(card)
            }
            if save {
                try context.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSuspended(_ card: Card, suspended: Bool, context: ModelContext) {
        setSuspended(cards: [card], suspended: suspended, context: context)
    }

    /// - Parameters:
    ///   - updateDeckStats: When false, skip per-card counter churn (use after large batches with `DeckStats.recomputeCounts`).
    ///   - save: When false, leave saving to the caller so many chunks can commit once.
    func setSuspended(
        cards: [Card],
        suspended: Bool,
        context: ModelContext,
        updateDeckStats: Bool = true,
        save: Bool = true
    ) {
        guard !cards.isEmpty else { return }
        do {
            for card in cards {
                let was = card.isSuspended
                guard was != suspended else { continue }
                card.isSuspended = suspended
                card.updatedAt = .now
                if updateDeckStats {
                    DeckStats.noteSuspensionChanged(card: card, wasSuspended: was)
                }
            }
            if save {
                try context.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveCards(
        _ cards: [Card],
        to destination: Deck,
        context: ModelContext,
        updateDeckStats: Bool = true,
        save: Bool = true
    ) {
        guard !cards.isEmpty else { return }
        do {
            for card in cards {
                let old = card.deck
                guard old?.id != destination.id else { continue }
                if updateDeckStats {
                    DeckStats.noteMoved(card: card, from: old, to: destination)
                }
                card.deck = destination
                card.deckName = destination.name
                card.updatedAt = .now
            }
            destination.updatedAt = .now
            if save {
                try context.save()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveCardEdits(
        _ card: Card,
        front: String,
        back: String,
        tags: [String],
        context: ModelContext
    ) {
        do {
            let wasCloze = card.cardType == .cloze || ClozeParser.containsCloze(card.front)
            let nowCloze = ClozeParser.containsCloze(front)

            card.front = front
            card.back = back
            card.tags = tags
            card.refreshSearchBlob()
            card.updatedAt = .now

            if nowCloze {
                card.cardType = .cloze
                let numbers = ClozeParser.clozeNumbers(in: front)
                if card.clozeNumber == nil {
                    card.clozeNumber = numbers.first ?? 1
                }
            } else if wasCloze && !nowCloze {
                card.cardType = .basic
                card.clozeNumber = nil
                card.clozeOrdinal = nil
            }

            // Edits invalidate any LLM polish — rebuild cheap baseline immediately.
            VoiceScriptBaseline.apply(to: card)
            card.deck?.updatedAt = .now
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func allDecks(context: ModelContext) -> [Deck] {
        (try? context.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    func refreshDeckStatsIfNeeded(context: ModelContext) {
        DeckStats.refreshStaleCounts(context: context)
        Task {
            await DeckStats.backfillSearchBlobs(context: context)
        }
    }
}
