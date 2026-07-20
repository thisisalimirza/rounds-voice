import Foundation
import SwiftData
import SwiftUI
import UIKit

@Observable
@MainActor
final class ReviewSessionViewModel {
    let deck: Deck
    let studyFilter: StudyFilter
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
    private(set) var isSuspended = false

    private var sessionTask: Task<Void, Never>?
    private var captionTask: Task<Void, Never>?
    private var voicePolishTask: Task<Void, Never>?
    private var answerContinuation: CheckedContinuation<String, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var cardStartedAt: Date?
    private var pauseBeganAt: Date?
    private var didPersistStats = false
    private let nowPlaying = NowPlayingSession.shared
    private let liveActivity = ReviewLiveActivityController.shared

    init(
        deck: Deck,
        studyFilter: StudyFilter = StudyFilter(),
        scheduler: any Scheduler = FSRSScheduler(),
        grader: any AIGraderService = HeuristicAnswerGrader(),
        voice: any VoiceManaging
    ) {
        self.deck = deck
        self.studyFilter = studyFilter
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
        errorMessage = nil
        guard let context = deck.modelContext else {
            queue = []
            status = .finished
            errorMessage = "Couldn't open this deck's cards."
            return
        }

        // Never materialize all 40k cards — session queue is a bounded due fetch.
        let sessionLimit = 60
        do {
            var due = try CardQuery.fetchDue(
                deckID: deck.id,
                limit: sessionLimit * 2,
                context: context,
                studyFilter: studyFilter
            )
            if due.isEmpty {
                due = try CardQuery.fetchUpcoming(
                    deckID: deck.id,
                    limit: min(20, sessionLimit) * 2,
                    context: context,
                    studyFilter: studyFilter
                )
            }
            // Anki-style: at most one sibling (same note) per session queue snapshot.
            queue = Array(SiblingBurial.filterQueueRemovingSiblingDuplicates(due).prefix(sessionLimit))
            for card in queue {
                card.ensureVoiceScriptReady()
            }
        } catch {
            queue = []
            errorMessage = error.localizedDescription
        }

        stats = ReviewSessionStats()
        status = .idle
        needsPermissions = false
        liveTranscript = ""
        isSuspended = false
        cardStartedAt = nil
        pauseBeganAt = nil
        didPersistStats = false
        sessionTask?.cancel()
        captionTask?.cancel()
        voicePolishTask?.cancel()
        finishPendingAnswer(with: "")
        finishResumeWait()
        // Polish upcoming scripts online — never blocks the first speak.
        scheduleVoicePolish(from: 0, count: min(40, queue.count))
        sessionTask = Task { await runSession() }
    }

    func stop() {
        endPauseClockIfNeeded()
        persistStatsIfNeeded()
        sessionTask?.cancel()
        sessionTask = nil
        captionTask?.cancel()
        captionTask = nil
        voicePolishTask?.cancel()
        voicePolishTask = nil
        finishPendingAnswer(with: "")
        finishResumeWait()
        voice.cancel()
        voice.endReviewAudio()
        nowPlaying.deactivate()
        liveActivity.end()
        UIApplication.shared.isIdleTimerDisabled = false
        status = .paused
        isSuspended = false
    }

    /// Re-assert audio after returning to foreground (lock is fine — this is unlock/active).
    func reassertAfterBecomingActive() {
        guard sessionTask != nil else { return }
        Task {
            try? await voice.reassertAudioSession()
            publishSessionChrome()
        }
    }

    /// Manual / typed override — wins the race against live listening.
    func submitAnswer(_ answer: String) {
        lastTranscript = answer
        finishPendingAnswer(with: answer)
    }

    func skip() {
        if isSuspended { resumeSession() }
        submitAnswer(VoiceCommand.skip.rawValue)
    }

    func markDontKnow() {
        if isSuspended { resumeSession() }
        submitAnswer(VoiceCommand.dontKnow.rawValue)
    }

    func repeatQuestion() {
        if isSuspended { resumeSession() }
        submitAnswer(VoiceCommand.repeat.rawValue)
    }

    func pauseSession() {
        guard !isSuspended else { return }
        isSuspended = true
        pauseBeganAt = .now
        voice.pause()
        status = .paused
        publishSessionChrome()
    }

    func resumeSession() {
        guard isSuspended else { return }
        endPauseClockIfNeeded()
        isSuspended = false
        voice.resume()
        publishSessionChrome()
        finishResumeWait()
    }

    private func runSession() async {
        UIApplication.shared.isIdleTimerDisabled = true
        nowPlaying.activate()
        liveActivity.start(deckName: deck.name)
        nowPlaying.onRemote = { [weak self] action in
            self?.handleRemote(action)
        }
        publishSessionChrome()

        do {
            try await voice.beginReviewAudio()
        } catch {
            errorMessage = error.localizedDescription
            status = .finished
            nowPlaying.deactivate()
            liveActivity.end()
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        let permitted = await voice.requestPermissions()
        guard permitted else {
            needsPermissions = true
            errorMessage = "Microphone and speech recognition are required for walking reviews."
            status = .finished
            voice.endReviewAudio()
            nowPlaying.deactivate()
            liveActivity.end()
            UIApplication.shared.isIdleTimerDisabled = false
            return
        }

        while !Task.isCancelled {
            await waitIfSuspended()
            guard !Task.isCancelled else { break }

            guard let card = queue.first else {
                status = .finished
                publishSessionChrome()
                persistStatsIfNeeded()
                try? await voice.speak("Session complete. Great work.")
                break
            }

            currentCard = card
            cardStartedAt = .now
            publishSessionChrome()
            let shouldAdvance = await present(card: card)
            if shouldAdvance {
                queue.removeAll { $0.id == card.id }
            }
        }

        persistStatsIfNeeded()
        voice.endReviewAudio()
        nowPlaying.deactivate()
        liveActivity.end()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func waitIfSuspended() async {
        guard isSuspended else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishResumeWait()
            resumeContinuation = continuation
        }
    }

    private func finishResumeWait() {
        if let resumeContinuation {
            self.resumeContinuation = nil
            resumeContinuation.resume()
        }
    }

    private func handleRemote(_ action: NowPlayingSession.RemoteAction) {
        switch action {
        case .pause:
            if isSuspended {
                resumeSession()
            } else {
                pauseSession()
            }
        case .resume:
            resumeSession()
        case .skip:
            skip()
        case .repeat:
            repeatQuestion()
        }
    }

    private func publishSessionChrome(includeTranscript: Bool = false) {
        let detail = sessionDetailText(includeTranscript: includeTranscript)
        nowPlaying.update(
            deckName: deck.name,
            detail: detail,
            isPlaying: !isSuspended && status != .finished && status != .paused
        )
        liveActivity.update(
            phase: status.activityPhase,
            detail: detail,
            cardsCompleted: stats.cardsCompleted,
            correctCount: stats.correctCount,
            queueRemaining: queue.count,
            isPaused: isSuspended || status == .paused
        )
    }

    private func sessionDetailText(includeTranscript: Bool = false) -> String {
        switch status {
        case .speaking:
            return currentCard.map { String($0.displayQuestion.prefix(60)) } ?? "Speaking…"
        case .listening:
            // Avoid pushing every partial onto Now Playing / Live Activity — stutter + battery.
            if includeTranscript, !liveTranscript.isEmpty {
                return String(liveTranscript.prefix(48))
            }
            return "Speak now…"
        case .thinking:
            return "Thinking…"
        case .correct:
            return "Correct"
        case .incorrect:
            return lastFeedback.isEmpty ? "Incorrect" : lastFeedback
        case .paused:
            return "Paused — tap play on AirPods to continue"
        case .finished:
            return "Session complete"
        case .idle:
            return "Ready"
        }
    }

    /// Returns `true` when the card should leave the queue.
    @discardableResult
    private func present(card: Card) async -> Bool {
        do {
            await waitIfSuspended()
            guard !Task.isCancelled else { return false }

            if voice.consumePromptReplayRequest() {
                try? await voice.speak("Audio glitch. Repeating the question.")
            }

            liveTranscript = ""
            status = .speaking
            publishSessionChrome()
            card.ensureVoiceScriptReady()
            let prompt = card.effectiveVoicePrompt
            let answer = card.effectiveVoiceAnswer
            prefetchNextPrompt(after: card)
            scheduleVoicePolishAhead(of: card)
            voice.prepareAnswerContext(
                question: prompt,
                expectedAnswer: answer
            )

            startCaptionPolling()
            let transcript: String
            do {
                transcript = try await voice.speakPromptAndCollectAnswer(
                    prompt: prompt,
                    maxDuration: 28
                )
            } catch is CancellationError {
                stopCaptionPolling()
                throw CancellationError()
            } catch {
                stopCaptionPolling()
                // Fallback: classic speak-then-listen if combined path fails.
                try await voice.speak(prompt)
                transcript = await collectAnswer()
            }
            stopCaptionPolling()
            lastTranscript = transcript
            liveTranscript = transcript
            publishSessionChrome()

            guard !Task.isCancelled else { return false }

            if voice.consumePromptReplayRequest() {
                return await present(card: card)
            }

            await waitIfSuspended()
            guard !Task.isCancelled else { return false }

            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                try? await voice.speak("I didn't catch that. Let's try again.")
                return await present(card: card)
            }

            if let command = VoiceCommand.detect(in: transcript) {
                return await handle(command: command, card: card)
            }

            status = .thinking
            publishSessionChrome()
            let grade = try await grader.gradeAnswer(
                question: prompt,
                expectedAnswer: answer,
                userAnswer: transcript
            )
            await apply(grade: grade, to: card)
            return true
        } catch is CancellationError {
            status = .paused
            publishSessionChrome()
            return false
        } catch {
            errorMessage = error.localizedDescription
            status = .idle
            publishSessionChrome()
            return false
        }
    }

    /// Race live speech (silence-complete) against manual UI commands / typed bridge.
    private func collectAnswer() async -> String {
        await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                do {
                    try await self.voice.startListening()
                    self.status = .listening
                    self.publishSessionChrome()
                    self.startCaptionPolling()
                    return try await self.voice.awaitAnswer(maxDuration: 28)
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
            var lastUIPush = Date.distantPast
            var lastChromePush = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date.now
                let partial = self.voice.partialTranscript

                // Throttle SwiftUI caption updates (~5 Hz) so the orb/atmosphere stay smooth.
                if partial != self.liveTranscript, now.timeIntervalSince(lastUIPush) >= 0.2 {
                    self.liveTranscript = partial
                    lastUIPush = now
                }

                if self.voice.state == .listening, self.status == .speaking {
                    self.status = .listening
                    self.publishSessionChrome()
                }
                if self.status == .listening, self.voice.state == .processing {
                    self.status = .thinking
                    self.publishSessionChrome()
                }

                // Occasional lock-screen caption refresh — never every partial.
                if self.status == .listening,
                   !partial.isEmpty,
                   now.timeIntervalSince(lastChromePush) >= 0.8 {
                    self.publishSessionChrome(includeTranscript: true)
                    lastChromePush = now
                }

                try? await Task.sleep(for: .milliseconds(160))
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
            pauseSession()
            await waitIfSuspended()
            return false
        case .explain:
            card.ensureVoiceScriptReady()
            let expected = card.effectiveVoiceAnswer
            let explanation = "The expected answer is \(expected)."
            lastFeedback = explanation
            status = .speaking
            publishSessionChrome()
            try? await voice.speak(explanation)
            let transcript = await collectAnswer()
            stopCaptionPolling()
            lastTranscript = transcript
            if transcript.isEmpty { return false }
            if let nested = VoiceCommand.detect(in: transcript) {
                return await handle(command: nested, card: card)
            }
            status = .thinking
            publishSessionChrome()
            do {
                let grade = try await grader.gradeAnswer(
                    question: card.effectiveVoicePrompt,
                    expectedAnswer: expected,
                    userAnswer: transcript
                )
                await apply(grade: grade, to: card)
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        case .resume:
            resumeSession()
            return false
        }
    }

    private func apply(grade: GradeResult, to card: Card) async {
        card.ensureVoiceScriptReady()
        let expected = card.effectiveVoiceAnswer
        let revealed = AnswerMatching.ensureAnswerRevealed(grade, expected: expected)
        let rating = ReviewRating(from: revealed, responseLatency: voice.lastResponseLatency)
        scheduler.recordReview(card: card, rating: rating)

        // Bury sister cloze cards until tomorrow so you don't grind the same note.
        if let context = deck.modelContext {
            _ = SiblingBurial.burySiblings(of: card, queue: &queue, context: context)
        }

        deck.lastReviewedAt = .now
        let cardSeconds: TimeInterval = {
            guard let started = cardStartedAt else { return 0 }
            return max(0, Date.now.timeIntervalSince(started))
        }()
        stats.record(grade: revealed, cardSeconds: cardSeconds)
        cardStartedAt = nil
        lastFeedback = revealed.feedback
        status = revealed.isCorrect ? .correct : .incorrect
        publishSessionChrome()

        let spoken = revealed.feedback.isEmpty
            ? (revealed.isCorrect ? "Correct." : "Incorrect. The answer is \(expected).")
            : revealed.feedback
        prefetchNextPrompt(after: card)
        try? await voice.speak(spoken)
        try? await Task.sleep(for: .milliseconds(revealed.isCorrect ? 350 : 700))
    }

    private func endPauseClockIfNeeded() {
        guard let began = pauseBeganAt else { return }
        stats.pausedSeconds += max(0, Date.now.timeIntervalSince(began))
        pauseBeganAt = nil
    }

    private func persistStatsIfNeeded() {
        guard !didPersistStats else { return }
        endPauseClockIfNeeded()
        guard stats.cardsCompleted > 0 else { return }
        didPersistStats = true
        _ = StudyStatsStore.saveSession(
            deck: deck,
            stats: stats,
            context: deck.modelContext
        )
    }

    private func prefetchNextPrompt(after card: Card) {
        guard let index = queue.firstIndex(where: { $0.id == card.id }),
              index + 1 < queue.count
        else { return }
        let next = queue[index + 1]
        next.ensureVoiceScriptReady()
        voice.prefetchSpeech(next.effectiveVoicePrompt)
        // Prefetch one more when possible for locked walks with flaky network.
        if index + 2 < queue.count {
            let after = queue[index + 2]
            after.ensureVoiceScriptReady()
            voice.prefetchSpeech(after.effectiveVoicePrompt)
        }
    }

    private func scheduleVoicePolishAhead(of card: Card) {
        guard let index = queue.firstIndex(where: { $0.id == card.id }) else { return }
        scheduleVoicePolish(from: index + 1, count: 10)
    }

    /// Background LLM polish for a slice of the queue. Never awaits on the speak path.
    private func scheduleVoicePolish(from start: Int, count: Int) {
        guard start < queue.count, count > 0 else { return }
        guard let context = deck.modelContext else { return }
        let end = min(start + count, queue.count)
        let slice = Array(queue[start..<end])
        guard !slice.isEmpty else { return }

        // Fire-and-forget; do not cancel earlier queue polish (already-LLM cards are skipped).
        let task = Task { @MainActor in
            await VoiceScriptService.polishIfNeeded(
                cards: slice,
                provider: AppSettings.shared.makeLLMProvider,
                context: context
            )
        }
        voicePolishTask = task
    }
}
