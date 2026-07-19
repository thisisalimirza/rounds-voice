import Foundation
import SwiftData

/// Fast, paged card access — never materialize `deck.cards` for large decks.
enum CardQuery {
    enum BrowserFilter: String, CaseIterable, Identifiable {
        case all
        case due
        case suspended

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .due: return "Due"
            case .suspended: return "Suspended"
            }
        }
    }

    struct Page: Sendable {
        var cards: [Card]
        var totalMatching: Int
    }

    static func fetchPage(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        offset: Int,
        limit: Int,
        context: ModelContext
    ) throws -> Page {
        let now = Date.now
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasSearch = !query.isEmpty

        let predicate: Predicate<Card>
        switch filter {
        case .all:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                }
            }
        case .due:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                }
            }
        case .suspended:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == true
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.isSuspended == true
                }
            }
        }

        var countDescriptor = FetchDescriptor<Card>(predicate: predicate)
        let totalMatching = try context.fetchCount(countDescriptor)

        var pageDescriptor = FetchDescriptor<Card>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.dueDate)]
        )
        pageDescriptor.fetchOffset = max(0, offset)
        pageDescriptor.fetchLimit = max(1, limit)

        let cards = try context.fetch(pageDescriptor)
        return Page(cards: cards, totalMatching: totalMatching)
    }

    static func fetchDue(
        deckID: UUID,
        limit: Int,
        context: ModelContext
    ) throws -> [Card] {
        let now = Date.now
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID
                    && $0.isSuspended == false
                    && $0.dueDate <= now
            },
            sortBy: [
                SortDescriptor(\.dueDate),
                SortDescriptor(\.reviewCount)
            ]
        )
        descriptor.fetchLimit = max(1, limit)
        return try context.fetch(descriptor)
    }

    static func fetchUpcoming(
        deckID: UUID,
        limit: Int,
        context: ModelContext
    ) throws -> [Card] {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false
            },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        descriptor.fetchLimit = max(1, limit)
        return try context.fetch(descriptor)
    }
}

/// Maintains denormalized deck counters so Home never loads 40k cards.
enum DeckStats {
    static func recomputeCounts(for deck: Deck, context: ModelContext) throws {
        let deckID = deck.id
        let now = Date.now

        var all = FetchDescriptor<Card>(predicate: #Predicate<Card> { $0.deck?.id == deckID })
        let cardCount = try context.fetchCount(all)

        var due = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false && $0.dueDate <= now
            }
        )
        let dueCount = try context.fetchCount(due)

        var suspended = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == true
            }
        )
        let suspendedCount = try context.fetchCount(suspended)

        deck.cardCount = cardCount
        deck.dueCount = dueCount
        deck.suspendedCount = suspendedCount
        deck.countsRefreshedAt = .now
    }

    /// One-shot / occasional refresh so overnight dues stay accurate without scanning relationships.
    static func refreshStaleCounts(context: ModelContext, olderThan hours: Double = 6) {
        do {
            let decks = try context.fetch(FetchDescriptor<Deck>())
            let cutoff = Date.now.addingTimeInterval(-hours * 3600)
            for deck in decks {
                let needs =
                    deck.countsRefreshedAt == nil
                    || (deck.countsRefreshedAt ?? .distantPast) < cutoff
                    || (deck.cardCount == 0 && deck.source != .sample)
                guard needs else { continue }
                try recomputeCounts(for: deck, context: context)
            }
            try context.save()
        } catch {
            // Best-effort — UI still uses last known counters.
        }
    }

    /// Fills `searchBlob` for cards imported before the field existed (batched, yielding).
    @MainActor
    static func backfillSearchBlobs(context: ModelContext) async {
        do {
            let decks = try context.fetch(FetchDescriptor<Deck>())
            for deck in decks {
                try await backfillSearchBlobs(deckID: deck.id, context: context)
            }
        } catch {
            // Best-effort.
        }
    }

    @MainActor
    static func backfillSearchBlobs(deckID: UUID, context: ModelContext) async throws {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.searchBlob == ""
            }
        )
        descriptor.fetchLimit = 300
        while true {
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }
            for card in batch {
                card.refreshSearchBlob()
            }
            try context.save()
            await Task.yield()
            if batch.count < 300 { break }
        }
    }

    static func noteInserted(card: Card, into deck: Deck) {
        deck.cardCount += 1
        if card.isSuspended {
            deck.suspendedCount += 1
        } else if card.dueDate <= .now {
            deck.dueCount += 1
        }
    }

    static func noteDeleted(card: Card, from deck: Deck) {
        deck.cardCount = max(0, deck.cardCount - 1)
        if card.isSuspended {
            deck.suspendedCount = max(0, deck.suspendedCount - 1)
        } else if card.dueDate <= .now {
            deck.dueCount = max(0, deck.dueCount - 1)
        }
    }

    static func noteSuspensionChanged(card: Card, wasSuspended: Bool) {
        guard let deck = card.deck, wasSuspended != card.isSuspended else { return }
        let isDue = card.dueDate <= .now
        if card.isSuspended {
            deck.suspendedCount += 1
            if isDue { deck.dueCount = max(0, deck.dueCount - 1) }
        } else {
            deck.suspendedCount = max(0, deck.suspendedCount - 1)
            if isDue { deck.dueCount += 1 }
        }
        deck.updatedAt = .now
    }

    static func noteReviewScheduled(card: Card, wasDue: Bool) {
        guard let deck = card.deck else { return }
        let isDue = !card.isSuspended && card.dueDate <= .now
        if wasDue && !isDue {
            deck.dueCount = max(0, deck.dueCount - 1)
        } else if !wasDue && isDue {
            deck.dueCount += 1
        }
    }
}
