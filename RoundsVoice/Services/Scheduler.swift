import Foundation
import SwiftData

/// Abstraction for spaced-repetition scheduling.
protocol Scheduler: AnyObject {
    func nextCard(from cards: [Card]) -> Card?
    func dueCards(from cards: [Card]) -> [Card]
    func recordReview(card: Card, rating: ReviewRating)
}
