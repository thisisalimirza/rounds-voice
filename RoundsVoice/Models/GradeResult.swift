import Foundation

/// Outcome of grading a spoken answer against the expected card back.
struct GradeResult: Sendable, Equatable {
    /// Whether the answer should be treated as "Good" for scheduling.
    var isCorrect: Bool

    /// Model confidence in the correctness judgment, 0.0–1.0.
    var confidence: Double

    /// Short professor-style feedback suitable for TTS.
    var feedback: String

    /// Optional 0–100 score for analytics / UI.
    var score: Int

    init(
        isCorrect: Bool,
        confidence: Double,
        feedback: String,
        score: Int? = nil
    ) {
        self.isCorrect = isCorrect
        self.confidence = min(max(confidence, 0), 1)
        self.feedback = feedback
        if let score {
            self.score = min(max(score, 0), 100)
        } else {
            self.score = isCorrect
                ? Int((confidence * 100).rounded())
                : Int(((1 - confidence) * 40).rounded())
        }
    }

    static let skipped = GradeResult(
        isCorrect: false,
        confidence: 1,
        feedback: "Skipped.",
        score: 0
    )

            static let unknown = GradeResult(
        isCorrect: false,
        confidence: 1,
        feedback: "Marked as don't know.",
        score: 0
    )
}

/// Rating applied to the spaced-repetition scheduler.
enum ReviewRating: String, Codable, Sendable, CaseIterable {
    case again
    case hard
    case good
    case easy

    /// Prefer Again / Good. Hard = correct but slow. Easy = correct and immediate.
    init(from grade: GradeResult, responseLatency: TimeInterval? = nil) {
        guard grade.isCorrect else {
            self = .again
            return
        }

        // Easy: first real words almost immediately after the mic is ready.
        if let latency = responseLatency, latency > 0, latency <= 2.5 {
            self = .easy
            return
        }

        // Hard: got it right, but it took a long time to produce an answer.
        if let latency = responseLatency, latency >= 14 {
            self = .hard
            return
        }

        // Default correct path — the common case.
        self = .good
    }
}

/// A single review event recorded during a session.
struct ReviewEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let cardID: UUID
    let rating: ReviewRating
    let grade: GradeResult
    let userAnswer: String
    let reviewedAt: Date

    init(
        id: UUID = UUID(),
        cardID: UUID,
        rating: ReviewRating,
        grade: GradeResult,
        userAnswer: String,
        reviewedAt: Date = .now
    ) {
        self.id = id
        self.cardID = cardID
        self.rating = rating
        self.grade = grade
        self.userAnswer = userAnswer
        self.reviewedAt = reviewedAt
    }
}
