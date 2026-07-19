import Foundation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ReviewSessionViewModel {
    let deck: Deck
    private let scheduler: any Scheduler
    private let grader: any AIGraderService
    private let voice: any VoiceManaging

    private(set) var queue: [Card] = []
    private(set) var currentCard: Card?
    private(set) var status: ReviewSessionStatus = .idle
    private(set) var stats = ReviewSessionStats()
    private(set) var lastFeedback: String = ""
    private(set) var lastTranscript: String = ""
    private(set) var liveTranscript: String = ""
    private(set) var errorMessage: String?
    private(set) var needsPermissions = false

    private var sessionTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    private var answerContinuation: CheckedContinuation<String, Never>?

    init(
        deck: Deck,
        scheduler: any Scheduler = SimplifiedFSRSScheduler(),
        grader: any AIGraderService = HeuristicAnswerGrader(),
        voice: any VoiceManaging
    ) {
        self.deck = deck
        self.scheduler = scheduler
        self.grader = grader
        self.voice = voice
    }

    var deckTitle: String { deck.name }

    var elapsedFormatted: String {
        let seconds = Int(stats.elapsed)
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    func start() {
        queue = scheduler.dueCards(from: deck.cards)
        if queue.isEmpty {
            queue = deck.cards.sorted { $0.dueDate < $1.dueDate }
        }
        stats = ReviewSessionStats()
        status = .idle
        errorMessage = nil
        needsPermissions = false
        liveTranscript = ""
        sessionTask?.cancel()
        captionTask?.cancel()
        finishPendingAnswer(with: "")
        sessionTask = Task { await runSession() }
    }

    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        captionTask?.cancel()
        captionTask = nil
        finishPendingAnswer(with: "")
        voice.cancel()
        status = .paused
    }

    /// Manual / typed override — wins the race against live listening.
    func submitAnswer(_ answer: String) {
        lastTranscript = answer
        finishPendingAnswer(with: answer)
    }

    func skip() {
        submitAnswer(VoiceCommand.skip.rawValue)
    }

    func markDontKnow() {
        submitAnswer(VoiceCommand.dontKnow.rawValue)
    }

    func repeatQuestion() {
        submitAnswer(VoiceCommand.repeat.rawValue)
    }

    func pauseSession() {
        voice.pause()
        status = .paused
    }

    private func runSession() async {
        do {
            try voice.configureAudioSession()
        } catch {
            errorMessage = error.localizedDescription
            status = .finished
            return
        }

        let permitted = await voice.requestPermissions()
        guard permitted else {
            needsPermissions = true
            errorMessage = "Microphone and speech recognition are required for walking reviews."
            status = .finished
            return
        }

        while !Task.isCancelled {
            guard let card = queue.first else {
                status = .finished
                try? await voice.speak("Session complete. Great work.")
                return
            }

            currentCard = card
            let shouldAdvance = await present(card: card)
            if shouldAdvance {
                queue.removeAll { $0.id == card.id }
            }
        }
    }

    /// Returns `true` when the card should leave the queue.
    @discardableResult
    private func present(card: Card) async -> Bool {
        do {
            liveTranscript = ""
            status = .speaking
            prefetchNextPrompt(after: card)
            try await voice.speak(card.spokenQuestion)
            guard !Task.isCancelled else { return false }

            status = .listening
            startCaptionPolling()
            prefetchNextPrompt(after: card)

            let transcript = await collectAnswer()
            stopCaptionPolling()
            lastTranscript = transcript
            liveTranscript = transcript

            guard !Task.isCancelled else { return false }
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // No speech and no manual input — ask again.
                try? await voice.speak("I didn't catch that. Let's try again.")
                return await present(card: card)
            }

            if let command = VoiceCommand.detect(in: transcript) {
                return await handle(command: command, card: card)
            }

            status = .thinking
            let grade = try await grader.gradeAnswer(
                question: card.spokenQuestion,
                expectedAnswer: card.spokenAnswer,
                userAnswer: transcript
            )
            await apply(grade: grade, to: card)
            return true
        } catch is CancellationError {
            status = .paused
            return false
        } catch {
            errorMessage = error.localizedDescription
            status = .idle
            return false
        }
    }

    /// Race live speech (silence-complete) against manual UI commands / typed bridge.
    private func collectAnswer() async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                do {
                    return try await self.voice.listenForAnswer(maxDuration: 28)
                } catch is CancellationError {
                    return ""
                } catch {
                    return ""
                }
            }

            group.addTask { @MainActor in
                await withTaskCancellationHandler {
                    await self.waitForManualAnswer()
                } onCancel: {
                    Task { @MainActor in
                        self.finishPendingAnswer(with: "")
                    }
                }
            }

            var chosen = ""
            for await result in group {
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    chosen = trimmed
                    // Resume the other waiter before cancelling the group.
                    self.finishPendingAnswer(with: "")
                    _ = await self.voice.stopListening()
                    group.cancelAll()
                    break
                }
            }

            self.finishPendingAnswer(with: "")
            _ = await self.voice.stopListening()
            return chosen
        }
    }

    private func waitForManualAnswer() async -> String {
        await withCheckedContinuation { continuation in
            finishPendingAnswer(with: "")
            answerContinuation = continuation
        }
    }

    private func finishPendingAnswer(with answer: String) {
        if let continuation = answerContinuation {
            answerContinuation = nil
            continuation.resume(returning: answer)
        }
    }

    private func startCaptionPolling() {
        captionTask?.cancel()
        captionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let partial = self.voice.partialTranscript
                if partial != self.liveTranscript {
                    self.liveTranscript = partial
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopCaptionPolling() {
        captionTask?.cancel()
        captionTask = nil
    }

    /// Returns whether the card should be removed from the queue.
    private func handle(command: VoiceCommand, card: Card) async -> Bool {
        switch command {
        case .repeat:
            return await present(card: card)
        case .skip:
            lastFeedback = "Skipped."
            try? await voice.speak("Skipped.")
            return true
        case .dontKnow:
            await apply(grade: .unknown, to: card)
            return true
        case .pause:
            voice.pause()
            status = .paused
            return false
        case .explain:
            let explanation = "The expected answer is \(card.spokenAnswer)."
            lastFeedback = explanation
            status = .speaking
            try? await voice.speak(explanation)
            status = .listening
            startCaptionPolling()
            let transcript = await collectAnswer()
            stopCaptionPolling()
            lastTranscript = transcript
            if transcript.isEmpty { return false }
            if let nested = VoiceCommand.detect(in: transcript) {
                return await handle(command: nested, card: card)
            }
            status = .thinking
            do {
                let grade = try await grader.gradeAnswer(
                    question: card.spokenQuestion,
                    expectedAnswer: card.spokenAnswer,
                    userAnswer: transcript
                )
                await apply(grade: grade, to: card)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        case .resume:
            voice.resume()
            status = .listening
            return false
        }
    }

    private func apply(grade: GradeResult, to card: Card) async {
        let rating = ReviewRating(from: grade)
        scheduler.recordReview(card: card, rating: rating)
        deck.lastReviewedAt = .now
        stats.record(grade: grade)
        lastFeedback = grade.feedback
        status = grade.isCorrect ? .correct : .incorrect

        let spoken = grade.feedback.isEmpty
            ? (grade.isCorrect ? "Correct." : "Incorrect.")
            : grade.feedback
        // Warm the next card while feedback speaks / short pause.
        prefetchNextPrompt(after: card)
        try? await voice.speak(spoken)
        try? await Task.sleep(for: .milliseconds(450))
    }

    private func prefetchNextPrompt(after card: Card) {
        guard let index = queue.firstIndex(where: { $0.id == card.id }),
              index + 1 < queue.count
        else { return }
        voice.prefetchSpeech(queue[index + 1].spokenQuestion)
    }
}
