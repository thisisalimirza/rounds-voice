import Foundation
import SwiftData

/// A flashcard suitable for voice-first review.
@Model
final class Card {
    @Attribute(.unique) var id: UUID
    var front: String
    var back: String
    var tags: [String]
    var deckName: String
    var dueDate: Date
    var interval: Double
    var easeFactor: Double
    var reviewCount: Int
    var lastReviewed: Date?
    var imageAttachments: [String]
    var cardType: CardType
    var clozeNumber: Int?
    /// When set, this card is one step in an AnKing one-by-one / sequential cloze chain.
    var clozeOrdinal: Int?
    var ankiNoteId: String?
    /// Anki-style suspend — excluded from due counts and review sessions.
    var isSuspended: Bool = false
    /// Lowercased plain text for fast SwiftData search predicates (no cloze parsing).
    var searchBlob: String = ""
    var createdAt: Date
    var updatedAt: Date

    var deck: Deck?

    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        tags: [String] = [],
        deckName: String,
        dueDate: Date = .now,
        interval: Double = 0,
        easeFactor: Double = 2.5,
        reviewCount: Int = 0,
        lastReviewed: Date? = nil,
        imageAttachments: [String] = [],
        cardType: CardType = .basic,
        clozeNumber: Int? = nil,
        clozeOrdinal: Int? = nil,
        ankiNoteId: String? = nil,
        isSuspended: Bool = false,
        deck: Deck? = nil
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.tags = tags
        self.deckName = deckName
        self.dueDate = dueDate
        self.interval = interval
        self.easeFactor = easeFactor
        self.reviewCount = reviewCount
        self.lastReviewed = lastReviewed
        self.imageAttachments = imageAttachments
        self.cardType = cardType
        self.clozeNumber = clozeNumber
        self.clozeOrdinal = clozeOrdinal
        self.ankiNoteId = ankiNoteId
        self.isSuspended = isSuspended
        self.deck = deck
        self.createdAt = .now
        self.updatedAt = .now
        self.searchBlob = Self.makeSearchBlob(front: front, back: back, tags: tags)
    }

    func refreshSearchBlob() {
        searchBlob = Self.makeSearchBlob(front: front, back: back, tags: tags)
    }

    static func makeSearchBlob(front: String, back: String, tags: [String]) -> String {
        let plainFront = AnkiHTMLCleaner.plainText(from: front)
        let plainBack = AnkiHTMLCleaner.plainText(from: back)
        return ([plainFront, plainBack] + tags)
            .joined(separator: " ")
            .lowercased()
    }

    /// Text the TTS engine should read (uses the word “blank”).
    var spokenQuestion: String {
        switch cardType {
        case .basic:
            return AnkiHTMLCleaner.plainText(from: front)
        case .cloze:
            if let ordinal = clozeOrdinal {
                return ClozeParser.spokenQuestionSequential(from: front, activeOrdinal: ordinal)
            }
            return ClozeParser.spokenQuestion(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
        }
    }

    /// On-screen prompt (Anki-style `[...]` blanks — never the word “blank”).
    var displayQuestion: String {
        switch cardType {
        case .basic:
            return AnkiHTMLCleaner.plainText(from: front)
        case .cloze:
            if let ordinal = clozeOrdinal {
                return ClozeParser.displayQuestionSequential(from: front, activeOrdinal: ordinal)
            }
            return ClozeParser.displayQuestion(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
        }
    }

    var spokenAnswer: String {
        switch cardType {
        case .basic:
            return AnkiHTMLCleaner.plainText(from: back)
        case .cloze:
            if let ordinal = clozeOrdinal {
                return ClozeParser.spokenAnswerSequential(from: front, activeOrdinal: ordinal)
            }
            let fromCloze = ClozeParser.spokenAnswer(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
            if !fromCloze.isEmpty { return fromCloze }
            return AnkiHTMLCleaner.plainText(from: back)
        }
    }

    var isDue: Bool {
        !isSuspended && dueDate <= .now
    }
}

enum CardType: String, Codable, CaseIterable, Sendable {
    case basic
    case cloze
}
