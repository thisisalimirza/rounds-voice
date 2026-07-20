import Foundation
import SwiftData

/// Persisted snapshot of a finished (or abandoned) walking review session.
@Model
final class StudySessionSummary {
    @Attribute(.unique) var id: UUID
    var deckID: UUID?
    var deckName: String
    var startedAt: Date
    var endedAt: Date
    var cardsCompleted: Int
    var correctCount: Int
    /// Wall time actively reviewing (excludes long pauses when possible).
    var elapsedSeconds: Double
    /// Sum of per-card answer times for a truer average.
    var totalCardSeconds: Double

    init(
        id: UUID = UUID(),
        deckID: UUID? = nil,
        deckName: String,
        startedAt: Date,
        endedAt: Date = .now,
        cardsCompleted: Int,
        correctCount: Int,
        elapsedSeconds: Double,
        totalCardSeconds: Double
    ) {
        self.id = id
        self.deckID = deckID
        self.deckName = deckName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.cardsCompleted = cardsCompleted
        self.correctCount = correctCount
        self.elapsedSeconds = elapsedSeconds
        self.totalCardSeconds = totalCardSeconds
    }

    var accuracy: Double {
        guard cardsCompleted > 0 else { return 0 }
        return Double(correctCount) / Double(cardsCompleted)
    }

    var accuracyPercent: Int {
        Int((accuracy * 100).rounded())
    }

    var averageSecondsPerCard: Double {
        guard cardsCompleted > 0 else { return 0 }
        if totalCardSeconds > 0 {
            return totalCardSeconds / Double(cardsCompleted)
        }
        return elapsedSeconds / Double(cardsCompleted)
    }
}

/// Aggregated study analytics for the Stats screen.
enum StudyStats {
    struct Snapshot: Equatable, Sendable {
        var cardsStudied: Int
        var correctCount: Int
        var elapsedSeconds: Double
        var totalCardSeconds: Double
        var sessionCount: Int

        static let empty = Snapshot(
            cardsStudied: 0,
            correctCount: 0,
            elapsedSeconds: 0,
            totalCardSeconds: 0,
            sessionCount: 0
        )

        var accuracyPercent: Int {
            guard cardsStudied > 0 else { return 0 }
            return Int((Double(correctCount) / Double(cardsStudied) * 100).rounded())
        }

        var averageSecondsPerCard: Double {
            guard cardsStudied > 0 else { return 0 }
            if totalCardSeconds > 0 {
                return totalCardSeconds / Double(cardsStudied)
            }
            return elapsedSeconds / Double(cardsStudied)
        }

        var studiedMinutes: Int {
            Int((elapsedSeconds / 60).rounded())
        }
    }

    static func aggregate(
        sessions: [StudySessionSummary],
        since start: Date? = nil,
        until end: Date? = nil
    ) -> Snapshot {
        var snap = Snapshot.empty
        for session in sessions {
            if let start, session.endedAt < start { continue }
            if let end, session.endedAt > end { continue }
            snap.cardsStudied += session.cardsCompleted
            snap.correctCount += session.correctCount
            snap.elapsedSeconds += session.elapsedSeconds
            snap.totalCardSeconds += session.totalCardSeconds
            snap.sessionCount += 1
        }
        return snap
    }

    static func startOfToday(calendar: Calendar = .current, now: Date = .now) -> Date {
        calendar.startOfDay(for: now)
    }

    static func fetchSessions(context: ModelContext) throws -> [StudySessionSummary] {
        var descriptor = FetchDescriptor<StudySessionSummary>(
            sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return try context.fetch(descriptor)
    }
}
