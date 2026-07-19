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
        do {
            if let deck = card.deck {
                deck.cards.removeAll { $0.id == card.id }
                deck.updatedAt = .now
            }
            context.delete(card)
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
