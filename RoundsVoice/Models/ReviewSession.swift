import Foundation

/// Live stats for an in-progress voice review session.
struct ReviewSessionStats: Sendable, Equatable {
    var cardsCompleted: Int = 0
    var correctCount: Int = 0
    var startedAt: Date = .now

    var accuracy: Double {
        guard cardsCompleted > 0 else { return 0 }
        return Double(correctCount) / Double(cardsCompleted)
    }

    var accuracyPercent: Int {
        Int((accuracy * 100).rounded())
    }

    var elapsed: TimeInterval {
        Date.now.timeIntervalSince(startedAt)
    }

    mutating func record(grade: GradeResult) {
        cardsCompleted += 1
        if grade.isCorrect {
            correctCount += 1
        }
    }
}

/// High-level status shown on the review session screen.
enum ReviewSessionStatus: String, Sendable, Equatable {
    case idle
    case speaking
    case listening
    case thinking
    case correct
    case incorrect
    case paused
    case finished

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .speaking: return "Speaking…"
        case .listening: return "Speak now"
        case .thinking: return "Thinking…"
        case .correct: return "Correct"
        case .incorrect: return "Incorrect"
        case .paused: return "Paused"
        case .finished: return "Session complete"
        }
    }

    var activityPhase: ReviewActivityAttributes.ContentState.Phase {
        switch self {
        case .idle: return .idle
        case .speaking: return .speaking
        case .listening: return .listening
        case .thinking: return .thinking
        case .correct: return .correct
        case .incorrect: return .incorrect
        case .paused: return .paused
        case .finished: return .finished
        }
    }
}

/// Hands-free voice commands recognized during a session.
enum VoiceCommand: String, CaseIterable, Sendable {
    case `repeat` = "repeat"
    case skip = "skip"
    case dontKnow = "i don't know"
    case pause = "pause"
    case explain = "explain"
    case resume = "resume"

    static func detect(in transcript: String) -> VoiceCommand? {
        let compact = normalize(transcript)
        guard !compact.isEmpty else { return nil }

        if isDontKnow(compact) {
            return .dontKnow
        }

        // Exact or near-exact command phrases only — avoid false positives in real answers.
        let commandMap: [(VoiceCommand, [String])] = [
            (.repeat, ["repeat", "say again", "again", "what was that"]),
            (.skip, ["skip", "next card", "next"]),
            (.pause, ["pause", "hold on", "wait"]),
            (.explain, ["explain", "tell me the answer", "whats the answer"]),
            (.resume, ["resume", "continue", "keep going"])
        ]

        for (command, phrases) in commandMap {
            let normalizedPhrases = phrases.map(normalize)
            if normalizedPhrases.contains(where: { compact == $0 || compact == "please \($0)" }) {
                return command
            }
        }

        return nil
    }

    /// True when the utterance is a complete hands-free command (used to end listening early).
    static func isCompleteCommand(_ transcript: String) -> Bool {
        detect(in: transcript) != nil
    }

    private static func normalize(_ transcript: String) -> String {
        transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            // Drop punctuation so "I don't know." / "I don't know!" still match.
            .replacingOccurrences(of: #"[^\w\s]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDontKnow(_ compact: String) -> Bool {
        let stripped = stripLeadingFillers(compact)

        let exact: Set<String> = [
            "i dont know",
            "dont know",
            "i do not know",
            "do not know",
            "no idea",
            "i have no idea",
            "have no idea",
            "no clue",
            "i have no clue",
            "pass",
            "idk",
            "not sure",
            "im not sure",
            "i am not sure",
            "i give up",
            "give up",
            "i dont know the answer",
            "dont know the answer",
            "i dont know this one",
            "dont know this one",
            "i dont know this",
            "i dont know that"
        ]

        if exact.contains(stripped) {
            return true
        }

        let giveUpPrefixes = [
            "i dont know",
            "dont know",
            "i do not know",
            "im not sure",
            "i am not sure"
        ]
        let allowedSuffixes = [
            "",
            " the answer",
            " this one",
            " this",
            " that",
            " anymore",
            " sorry"
        ]

        for prefix in giveUpPrefixes {
            guard stripped == prefix || stripped.hasPrefix(prefix + " ") else { continue }
            let suffix = String(stripped.dropFirst(prefix.count))
            if allowedSuffixes.contains(suffix) {
                return true
            }
        }

        return false
    }

    private static func stripLeadingFillers(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let fillers: Set<String> = [
            "um", "uh", "uhm", "hmm", "hm", "like", "so", "well",
            "yeah", "yes", "okay", "ok", "alright", "oh", "ah"
        ]
        while let first = words.first, fillers.contains(first) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }
}
