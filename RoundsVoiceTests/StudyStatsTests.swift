import Foundation
import SwiftData
import Testing
@testable import RoundsVoice

@MainActor
struct StudyStatsTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Deck.self, Card.self, StudySessionSummary.self])
        return try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func aggregatesTodayAndAveragePerCard() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deck = Deck(name: "Stats Deck", source: .manual)
        context.insert(deck)

        var stats = ReviewSessionStats()
        stats.cardsCompleted = 10
        stats.correctCount = 7
        stats.totalCardSeconds = 200
        stats.startedAt = Date.now.addingTimeInterval(-300)

        let saved = StudyStatsStore.saveSession(deck: deck, stats: stats, context: context)
        #expect(saved != nil)

        let sessions = try StudyStats.fetchSessions(context: context)
        let today = StudyStats.aggregate(sessions: sessions, since: StudyStats.startOfToday())
        #expect(today.cardsStudied == 10)
        #expect(today.accuracyPercent == 70)
        #expect(abs(today.averageSecondsPerCard - 20) < 0.01)
        #expect(today.sessionCount == 1)
    }

    @Test func ignoresEmptySessions() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let deck = Deck(name: "Empty", source: .manual)
        context.insert(deck)
        let saved = StudyStatsStore.saveSession(
            deck: deck,
            stats: ReviewSessionStats(),
            context: context
        )
        #expect(saved == nil)
    }
}
