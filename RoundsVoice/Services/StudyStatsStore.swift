import Foundation
import SwiftData

/// Persists review session summaries for the Stats screen.
enum StudyStatsStore {
    @discardableResult
    static func saveSession(
        deck: Deck,
        stats: ReviewSessionStats,
        context: ModelContext?
    ) -> StudySessionSummary? {
        guard let context else { return nil }
        guard stats.cardsCompleted > 0 else { return nil }

        let ended = Date.now
        let elapsed = max(0, ended.timeIntervalSince(stats.startedAt) - stats.pausedSeconds)
        let summary = StudySessionSummary(
            deckID: deck.id,
            deckName: deck.name,
            startedAt: stats.startedAt,
            endedAt: ended,
            cardsCompleted: stats.cardsCompleted,
            correctCount: stats.correctCount,
            elapsedSeconds: elapsed,
            totalCardSeconds: stats.totalCardSeconds
        )
        context.insert(summary)
        do {
            try context.save()
            return summary
        } catch {
            return nil
        }
    }
}
