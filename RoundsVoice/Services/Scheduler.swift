import Foundation
import SwiftData

/// Abstraction for spaced-repetition scheduling.
/// Phase 5 can swap in a full FSRS implementation without touching session UI.
protocol Scheduler: AnyObject {
    func nextCard(from cards: [Card]) -> Card?
    func dueCards(from cards: [Card]) -> [Card]
    func recordReview(card: Card, rating: ReviewRating)
}

/// Simplified FSRS-compatible scheduler for MVP.
///
/// Uses SM-2–inspired interval growth with FSRS-like rating semantics
/// (Again / Hard / Good / Easy) so a real FSRS engine can replace this later.
@MainActor
final class SimplifiedFSRSScheduler: Scheduler {
    /// Minimum interval after a successful review (days).
    private let learningStepsDays: [Double] = [0.0104, 0.0417] // ~15m, ~1h expressed in days

    func dueCards(from cards: [Card]) -> [Card] {
        cards
            .filter(\.isDue)
            .sorted { lhs, rhs in
                if lhs.dueDate != rhs.dueDate {
                    return lhs.dueDate < rhs.dueDate
                }
                return lhs.reviewCount < rhs.reviewCount
            }
    }

    func nextCard(from cards: [Card]) -> Card? {
        dueCards(from: cards).first
    }

    func recordReview(card: Card, rating: ReviewRating) {
        let now = Date.now
        card.lastReviewed = now
        card.reviewCount += 1
        card.updatedAt = now

        switch rating {
        case .again:
            card.easeFactor = max(1.3, card.easeFactor - 0.2)
            card.interval = 0
            card.dueDate = now.addingTimeInterval(10 * 60) // 10 minutes

        case .hard:
            card.easeFactor = max(1.3, card.easeFactor - 0.15)
            if card.interval < 1 {
                card.interval = learningStepsDays.last ?? 1
            } else {
                card.interval = max(1, card.interval * 1.2)
            }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)

        case .good:
            if card.interval < 1 {
                card.interval = 1
            } else {
                card.interval = card.interval * card.easeFactor
            }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)

        case .easy:
            card.easeFactor = min(3.0, card.easeFactor + 0.15)
            if card.interval < 1 {
                card.interval = 3
            } else {
                card.interval = card.interval * card.easeFactor * 1.3
            }
            card.dueDate = now.addingTimeInterval(card.interval * 86_400)
        }
    }
}
