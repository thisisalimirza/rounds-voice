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
        self.createdAt = .now
        self.updatedAt = .now
        self.lastReviewedAt = lastReviewedAt
    }

    var dueCardCount: Int {
        cards.filter(\.isDue).count
    }

    var totalCardCount: Int {
        cards.count
    }
}

enum DeckSource: String, Codable, CaseIterable, Sendable {
    case sample
    case ankiImport
    case manual
}
