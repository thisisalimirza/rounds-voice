import ActivityKit
import Foundation

/// Shared between the app and the Live Activity widget extension.
struct ReviewActivityAttributes: ActivityAttributes {
    /// Fixed for the life of one review session.
    var deckName: String

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        var detail: String
        var cardsCompleted: Int
        var correctCount: Int
        var queueRemaining: Int
        var isPaused: Bool

        enum Phase: String, Codable, Hashable, Sendable {
            case idle
            case speaking
            case listening
            case thinking
            case correct
            case incorrect
            case paused
            case finished

            var title: String {
                switch self {
                case .idle: return "Ready"
                case .speaking: return "Speaking"
                case .listening: return "Speak now"
                case .thinking: return "Thinking"
                case .correct: return "Correct"
                case .incorrect: return "Incorrect"
                case .paused: return "Paused"
                case .finished: return "Done"
                }
            }

            var symbolName: String {
                switch self {
                case .idle: return "stethoscope"
                case .speaking: return "waveform"
                case .listening: return "mic.fill"
                case .thinking: return "brain.head.profile"
                case .correct: return "checkmark.circle.fill"
                case .incorrect: return "xmark.circle.fill"
                case .paused: return "pause.circle.fill"
                case .finished: return "flag.checkered"
                }
            }

            var compactLabel: String {
                switch self {
                case .idle: return "Ready"
                case .speaking: return "TTS"
                case .listening: return "Mic"
                case .thinking: return "…"
                case .correct: return "✓"
                case .incorrect: return "✗"
                case .paused: return "‖"
                case .finished: return "Done"
                }
            }
        }
    }
}
