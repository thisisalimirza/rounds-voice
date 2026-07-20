import Foundation
import SwiftData

/// Card learning state for FSRS (matches Anki / open-spaced-repetition).
enum FSRSState: Int, Codable, Sendable, CaseIterable {
    case new = 0
    case learning = 1
    case review = 2
    case relearning = 3
}

/// Production FSRS-4.5 scheduler (Anki-compatible defaults).
///
/// Uses the published open-spaced-repetition formulas with default weights.
/// Voice ratings map to Again / Hard / Good / Easy.
@MainActor
final class FSRSScheduler: Scheduler {
    /// Default FSRS-4.5 weights (Anki).
    static let defaultWeights: [Double] = [
        0.4, 0.6, 2.4, 5.8, 4.93, 0.94, 0.86, 0.01, 1.49, 0.14, 0.94,
        2.18, 0.05, 0.34, 1.26, 0.29, 2.61
    ]

    var weights: [Double]
    var requestRetention: Double
    var maximumInterval: Double

    init(
        weights: [Double] = FSRSScheduler.defaultWeights,
        requestRetention: Double = 0.9,
        maximumInterval: Double = 36500
    ) {
        self.weights = weights
        self.requestRetention = requestRetention
        self.maximumInterval = maximumInterval
    }

    func dueCards(from cards: [Card]) -> [Card] {
        cards
            .filter { $0.isDue && !$0.isBuried }
            .sorted { lhs, rhs in
                if lhs.dueDate != rhs.dueDate { return lhs.dueDate < rhs.dueDate }
                return lhs.reviewCount < rhs.reviewCount
            }
    }

    func nextCard(from cards: [Card]) -> Card? {
        dueCards(from: cards).first
    }

    func recordReview(card: Card, rating: ReviewRating) {
        let now = Date.now
        let wasDue = card.isDue
        let ratingValue = rating.fsrsValue
        let state = FSRSState(rawValue: card.fsrsState) ?? .new

        let elapsedDays: Double = {
            guard let last = card.lastReviewed else { return 0 }
            return max(0, now.timeIntervalSince(last) / 86_400)
        }()

        let scheduledDays = max(card.interval, 0)
        let retrievability: Double = {
            guard state == .review || state == .relearning, card.stability > 0 else { return 1 }
            return forgettingCurve(elapsedDays: elapsedDays, stability: card.stability)
        }()

        switch state {
        case .new:
            applyNew(card: card, rating: ratingValue, now: now)
        case .learning, .relearning:
            applyLearning(card: card, rating: ratingValue, now: now)
        case .review:
            applyReview(
                card: card,
                rating: ratingValue,
                elapsedDays: elapsedDays,
                scheduledDays: scheduledDays,
                retrievability: retrievability,
                now: now
            )
        }

        card.lastReviewed = now
        card.reviewCount += 1
        card.reps += 1
        card.updatedAt = now
        // Keep legacy easeFactor roughly aligned for UI / export familiarity.
        card.easeFactor = min(3.0, max(1.3, 1.3 + (10 - card.difficulty) * 0.1))

        DeckStats.noteReviewScheduled(card: card, wasDue: wasDue)
        try? card.modelContext?.save()
    }

    // MARK: - State transitions

    private func applyNew(card: Card, rating: Int, now: Date) {
        card.difficulty = initDifficulty(rating)
        card.stability = initStability(rating)
        card.lapses = rating == 1 ? card.lapses + 1 : card.lapses

        switch rating {
        case 1:
            card.fsrsState = FSRSState.learning.rawValue
            schedule(card: card, days: min(nextInterval(stability: card.stability), 10.0 / 1440.0), now: now)
        case 2:
            card.fsrsState = FSRSState.learning.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        case 3:
            card.fsrsState = FSRSState.review.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        default:
            card.fsrsState = FSRSState.review.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability) * 1.3, now: now)
        }
    }

    private func applyLearning(card: Card, rating: Int, now: Date) {
        switch rating {
        case 1:
            card.lapses += 1
            card.stability = initStability(1)
            card.difficulty = nextDifficulty(d: card.difficulty, rating: rating)
            card.fsrsState = FSRSState.relearning.rawValue
            schedule(card: card, days: min(nextInterval(stability: card.stability), 10.0 / 1440.0), now: now)
        case 2:
            card.difficulty = nextDifficulty(d: card.difficulty, rating: rating)
            card.stability = max(card.stability, initStability(2))
            card.fsrsState = FSRSState.learning.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        case 3:
            card.difficulty = nextDifficulty(d: card.difficulty, rating: rating)
            card.stability = max(card.stability, initStability(3))
            card.fsrsState = FSRSState.review.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        default:
            card.difficulty = nextDifficulty(d: card.difficulty, rating: rating)
            card.stability = max(card.stability, initStability(4))
            card.fsrsState = FSRSState.review.rawValue
            schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        }
    }

    private func applyReview(
        card: Card,
        rating: Int,
        elapsedDays: Double,
        scheduledDays: Double,
        retrievability: Double,
        now: Date
    ) {
        let d = card.difficulty > 0 ? card.difficulty : initDifficulty(3)
        let s = card.stability > 0 ? card.stability : initStability(3)

        if rating == 1 {
            card.lapses += 1
            card.difficulty = nextDifficulty(d: d, rating: rating)
            card.stability = nextForgetStability(d: card.difficulty, s: s, r: retrievability)
            card.fsrsState = FSRSState.relearning.rawValue
            schedule(card: card, days: min(nextInterval(stability: card.stability), 20.0 / 1440.0), now: now)
            return
        }

        card.difficulty = nextDifficulty(d: d, rating: rating)
        card.stability = nextRecallStability(
            d: card.difficulty,
            s: s,
            r: retrievability,
            rating: rating
        )
        card.fsrsState = FSRSState.review.rawValue
        schedule(card: card, days: nextInterval(stability: card.stability), now: now)
        _ = scheduledDays
        _ = elapsedDays
    }

    private func schedule(card: Card, days: Double, now: Date) {
        let clamped = min(max(days, 1.0 / 1440.0), maximumInterval)
        card.interval = clamped
        card.dueDate = now.addingTimeInterval(clamped * 86_400)
    }

    // MARK: - FSRS formulas

    private func initStability(_ rating: Int) -> Double {
        max(weights[rating - 1], 0.1)
    }

    private func initDifficulty(_ rating: Int) -> Double {
        constrainDifficulty(weights[4] - exp(weights[5] * Double(rating - 1)) + 1)
    }

    private func nextDifficulty(d: Double, rating: Int) -> Double {
        let next = d - weights[6] * Double(rating - 3)
        return constrainDifficulty(meanReversion(weights[4], next))
    }

    private func meanReversion(_ initial: Double, _ current: Double) -> Double {
        weights[7] * initial + (1 - weights[7]) * current
    }

    private func constrainDifficulty(_ d: Double) -> Double {
        min(max(d, 1), 10)
    }

    private func nextRecallStability(d: Double, s: Double, r: Double, rating: Int) -> Double {
        let hardPenalty = rating == 2 ? weights[15] : 1.0
        let easyBonus = rating == 4 ? weights[16] : 1.0
        let growth = exp(weights[8])
            * (11 - d)
            * pow(s, -weights[9])
            * (exp((1 - r) * weights[10]) - 1)
            * hardPenalty
            * easyBonus
        return s * (1 + growth)
    }

    private func nextForgetStability(d: Double, s: Double, r: Double) -> Double {
        weights[11]
            * pow(d, -weights[12])
            * (pow(s + 1, weights[13]) - 1)
            * exp((1 - r) * weights[14])
    }

    /// FSRS-4.5 forgetting curve.
    func forgettingCurve(elapsedDays: Double, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + elapsedDays / (9 * stability), -1)
    }

    /// Interval (days) targeting `requestRetention`.
    func nextInterval(stability: Double) -> Double {
        guard stability > 0 else { return 1.0 / 1440.0 }
        let interval = 9 * stability * (1 / requestRetention - 1)
        return min(max(interval, 1.0 / 1440.0), maximumInterval)
    }
}

extension ReviewRating {
    /// FSRS rating integers: Again=1 … Easy=4.
    var fsrsValue: Int {
        switch self {
        case .again: return 1
        case .hard: return 2
        case .good: return 3
        case .easy: return 4
        }
    }
}

/// Back-compat alias — session defaults to real FSRS now.
typealias SimplifiedFSRSScheduler = FSRSScheduler
