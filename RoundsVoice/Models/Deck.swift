import Foundation
import SwiftData

/// A named collection of cards, typically corresponding to an Anki deck.
@Model
final class Deck {
    @Attribute(.unique) var id: UUID
    var name: String
    var deckDescription: String
    var source: DeckSource
    var createdAt: Date
    var updatedAt: Date
    var lastReviewedAt: Date?

    /// Denormalized counters — never derive these from `cards` for large decks.
    var cardCount: Int = 0
    var dueCount: Int = 0
    var suspendedCount: Int = 0
    var countsRefreshedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Card.deck)
    var cards: [Card]

    init(
        id: UUID = UUID(),
        name: String,
        deckDescription: String = "",
        source: DeckSource = .sample,
        cards: [Card] = [],
        lastReviewedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.deckDescription = deckDescription
        self.source = source
        self.cards = cards
        self.cardCount = cards.count
        self.dueCount = cards.filter { !$0.isSuspended && $0.dueDate <= .now }.count
        self.suspendedCount = cards.filter(\.isSuspended).count
        self.countsRefreshedAt = .now
        self.createdAt = .now
        self.updatedAt = .now
        self.lastReviewedAt = lastReviewedAt
    }

    var dueCardCount: Int { dueCount }
    var totalCardCount: Int { cardCount }
}

enum DeckSource: String, Codable, CaseIterable, Sendable {
    case sample
    case ankiImport
    case manual
}
