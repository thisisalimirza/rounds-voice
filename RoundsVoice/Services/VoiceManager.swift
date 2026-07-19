import AVFoundation
import Foundation
import Speech
#if canImport(UIKit)
import UIKit
#endif

/// States exposed to the review UI for the voice pipeline.
enum VoiceEngineState: Equatable, Sendable {
    case idle
    case speaking
    case listening
    case processing
    case paused
    case error(String)
}

enum VoiceError: LocalizedError, Sendable {
    case recognizerUnavailable
    case permissionDenied
    case audioEngineFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognition isn't available on this device."
        case .permissionDenied:
            return "Microphone or speech recognition permission was denied."
        case .audioEngineFailed(let detail):
            return "Couldn't start listening: \(detail)"
        case .cancelled:
            return "Listening was cancelled."
        }
    }
}

/// Hands-free voice pipeline: TTS → listen → silence detect → transcript.
@MainActor
protocol VoiceManaging: AnyObject {
    var state: VoiceEngineState { get }
    var lastTranscript: String { get }
    var partialTranscript: String { get }
    /// Set after an audio interruption mid-prompt — ViewModel should re-speak the card.
    var promptReplayRequested: Bool { get }

    /// Card-specific vocabulary for OpenAI STT + Apple contextual strings.
    func prepareAnswerContext(question: String, expectedAnswer: String)

    /// Start continuous audio (keep-alive) for a locked-screen walk session.
    func beginReviewAudio() async throws
    func endReviewAudio()
    func reassertAudioSession() async throws
    func consumePromptReplayRequest() -> Bool

    func configureAudioSession() async throws
    func requestPermissions() async -> Bool
    func speak(_ text: String) async throws
    func prefetchSpeech(_ text: String)
    /// Convenience: arm mic, then wait for an utterance.
    func listenForAnswer(maxDuration: TimeInterval) async throws -> String
    /// Start the mic / recognizer. Only returns once capture is actually running.
    func startListening() async throws
    /// Wait until silence (or timeout) after `startListening()`.
    func awaitAnswer(maxDuration: TimeInterval) async throws -> String
    func stopListening() async -> String
    func cancel()
    func pause()
    func resume()
}

@MainActor
final class VoiceManager: NSObject, VoiceManaging {
    private(set) var state: VoiceEngineState = .idle
    private(set) var lastTranscript: String = ""
    private(set) var partialTranscript: String = ""
    private(set) var promptReplayRequested = false

    /// End-of-answer silence before we finalize (snappy turn-taking).
    var silenceTimeout: TimeInterval = 0.75
    var commandSilenceTimeout: TimeInterval = 0.28
    var minimumSpeechDuration: TimeInterval = 0.15
    /// How long the caption must stay unchanged before we treat the utterance as done.
    var transcriptStableTimeout: TimeInterval = 0.70
    /// Peak above this counts as real speech energy (above AirPods hiss / room noise).
    var speechEnergyThreshold: Float = 0.028

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var pcmPlayer: PCMStreamPlayer?
    private var speechContinuation: CheckedContinuation<Void, Error>?
    private var speakGeneration = 0
    private var settings: AppSettings
    private let audio = ContinuousAudioSession.shared

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var micTapInstalled = false
    private let captureBuffer = AnswerAudioCapture()
    private var realtimeClient: RealtimeTranscriptionClient?
    private var pcmStreamOffset = 0
    private var usingOpenAISTT = false
    /// Bias STT toward this card's medical terms (set before listen).
    private var sttQuestionHint = ""
    private var sttExpectedAnswerHint = ""
    private var sttVocabularyHints: [String] = []
    private var wasSpeakingAtInterruption = false

    private var silenceTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var pcmPumpTask: Task<Void, Never>?
    private var listenContinuation: CheckedContinuation<String, Error>?
    private var lastSpeechDate: Date?
    private var firstSpeechDate: Date?
    /// Last time the caption text actually changed (not a duplicate Apple partial).
    private var lastTranscriptChangeDate: Date?
    private var listenStartedAt: Date?
    private var hasReceivedSpeech = false
    private var playbackWatchdog: Task<Void, Never>?
    private var finishListenTask: Task<Void, Never>?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    init(settings: AppSettings = .shared) {
        self.settings = settings
        super.init()
        synthesizer.delegate = self
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        installSessionObservers()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    // MARK: - Session

    func prepareAnswerContext(question: String, expectedAnswer: String) {
        sttQuestionHint = question
        sttExpectedAnswerHint = expectedAnswer
        sttVocabularyHints = Self.vocabularyHints(from: expectedAnswer + " " + question)
    }

    func beginReviewAudio() async throws {
        try await audio.beginReview()
    }

    func endReviewAudio() {
        removeMicTap()
        audio.endReview()
    }

    func reassertAudioSession() async throws {
        try await audio.reassert()
    }

    func consumePromptReplayRequest() -> Bool {
        let value = promptReplayRequested
        promptReplayRequested = false
        return value
    }

    /// Configures play-and-record via the continuous session (no deactivate between turns).
    func configureAudioSession(bounce: Bool = false) async throws {
        try await audio.configureSession(bounce: bounce)
        if audio.isReviewActive {
            try audio.ensureEngineRunning()
            audio.startKeepAlive()
        }
    }

    func configureAudioSession() async throws {
        try await configureAudioSession(bounce: false)
    }

    private static func vocabularyHints(from text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^\w\s\-/]"#, with: " ", options: .regularExpression)
        let parts = cleaned.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == "-" })
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            let token = String(part)
            guard token.count >= 3 else { continue }
            let key = token.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(token)
            if out.count >= 40 { break }
        }
        return out
    }

    /// Soft handoff to mic — keep shared engine alive.
    private func prepareForListening() async throws {
        stopCurrentSpeech(resumeContinuation: false)
        try await configureAudioSession(bounce: false)
        audio.resumeKeepAliveAfterTTS()
    }

    func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        // Warm the recognizer so the first listen isn't cold-start slow.
        _ = speechRecognizer?.isAvailable
        return micGranted && speechGranted
    }

    // MARK: - Text to speech

    func speak(_ text: String) async throws {
        cancelListeningPipeline(resumeListenContinuation: true)
        stopCurrentSpeech(resumeContinuation: true)
        speakGeneration += 1
        let generation = speakGeneration
        state = .speaking

        try await configureAudioSession(bounce: false)

        if let provider = settings.makeOpenAITTSProvider {
            do {
                try await speakWithOpenAI(text, provider: provider, generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard generation == speakGeneration else { throw CancellationError() }
                try await speakWithApple(text)
            }
        } else {
            try await speakWithApple(text)
        }

        guard generation == speakGeneration else { throw CancellationError() }
        // Stop TTS only — do NOT bounce the session here. Bouncing + sleeping after
        // speak() made the UI say "Listening" while the mic was still cold, which
        // clipped the first word of nearly every answer.
        stopCurrentSpeech(resumeContinuation: false)
    }

    func prefetchSpeech(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let provider = settings.makeOpenAITTSProvider else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            let key = provider.cacheKey(for: trimmed, format: "pcm")
            if await TTSAudioCache.shared.data(for: key) != nil { return }
            guard !Task.isCancelled else { return }
            do {
                let data = try await provider.synthesizePCM(text: trimmed)
                guard !Task.isCancelled else { return }
                await TTSAudioCache.shared.store(data, for: key)
            } catch {
                // Prefetch is best-effort.
            }
        }
    }

    private func speakWithOpenAI(
        _ text: String,
        provider: OpenAITTSProvider,
        generation: Int
    ) async throws {
        let key = provider.cacheKey(for: text, format: "pcm")
        if let cached = await TTSAudioCache.shared.data(for: key), cached.count > 256 {
            try await playPCMData(cached, generation: generation)
            return
        }

        // Stream for low time-to-first-audio; also assemble for cache.
        let player = PCMStreamPlayer()
        pcmPlayer = player
        try player.start()

        var assembled = Data()
        assembled.reserveCapacity(64_000)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.speechContinuation = continuation
            Task { @MainActor in
                do {
                    for try await chunk in provider.synthesizePCMStream(text: text) {
                        guard generation == self.speakGeneration else {
                            throw CancellationError()
                        }
                        assembled.append(chunk)
                        player.schedulePCM(chunk)
                    }
                    await player.finishAndWait()
                    if assembled.count > 256 {
                        await TTSAudioCache.shared.store(assembled, for: key)
                    }
                    self.pcmPlayer = nil
                    if let cont = self.speechContinuation {
                        self.speechContinuation = nil
                        self.state = .idle
                        cont.resume()
                    }
                } catch {
                    self.pcmPlayer?.stop()
                    self.pcmPlayer = nil
                    if let cont = self.speechContinuation {
                        self.speechContinuation = nil
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func playPCMData(_ data: Data, generation: Int) async throws {
        let player = PCMStreamPlayer()
        pcmPlayer = player
        try player.start()
        // Schedule in chunks so the engine stays responsive.
        let chunkSize = 4_800
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            // Align to 2 bytes.
            let alignedEnd = end - ((end - offset) % 2)
            if alignedEnd > offset {
                player.schedulePCM(data.subdata(in: offset..<alignedEnd))
            }
            offset = alignedEnd == offset ? end : alignedEnd
            if offset >= data.count { break }
        }
        await player.finishAndWait()
        guard generation == speakGeneration else { throw CancellationError() }
        pcmPlayer = nil
        state = .idle
    }

    private func speakWithApple(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = preferredEnglishVoice()
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.04

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.speechContinuation = continuation
            self.synthesizer.speak(utterance)
        }
    }

    private func stopCurrentSpeech(resumeContinuation: Bool) {
        let pending = speechContinuation
        speechContinuation = nil
        playbackWatchdog?.cancel()
        playbackWatchdog = nil

        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let player = audioPlayer {
            player.delegate = nil
            player.stop()
            audioPlayer = nil
        }
        pcmPlayer?.stop()
        pcmPlayer = nil

        if resumeContinuation, let continuation = pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    // MARK: - Speech recognition

    func listenForAnswer(maxDuration: TimeInterval = 28) async throws -> String {
        try await startListening()
        return try await awaitAnswer(maxDuration: maxDuration)
    }

    func awaitAnswer(maxDuration: TimeInterval = 28) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.listenContinuation = continuation
            self.startSilenceMonitor(maxDuration: maxDuration)
        }
    }

    func startListening() async throws {
        cancelListeningPipeline(resumeListenContinuation: false)

        lastTranscript = ""
        partialTranscript = ""
        lastSpeechDate = nil
        firstSpeechDate = nil
        lastTranscriptChangeDate = nil
        hasReceivedSpeech = false
        listenStartedAt = .now
        pcmStreamOffset = 0
        captureBuffer.reset()
        usingOpenAISTT = settings.shouldUseOpenAISTT
        // Stay idle until the mic is actually running.
        state = .idle

        try await prepareForListening()

        if usingOpenAISTT {
            await startOpenAIListening()
        } else {
            try await startAppleListening()
        }

        guard audio.isEngineRunning || micTapInstalled else {
            throw VoiceError.audioEngineFailed("Microphone failed to start.")
        }

        state = .listening
        signalMicReady()
    }

    private func signalMicReady() {
        audio.playMicReadyEarcon()
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.55)
        #endif
    }

    private var preferOnDeviceRecognition: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    private func startOpenAIListening() async {
        // Apple live captions + WAV capture for gpt-4o-transcribe.
        try? await startAppleListening(alongsideCapture: true)
    }

    private func startAppleListening(alongsideCapture: Bool = false) async throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            if !alongsideCapture && !usingOpenAISTT {
                state = .error("Recognizer unavailable")
                throw VoiceError.recognizerUnavailable
            }
            if recognitionRequest == nil {
                await installCaptureTap(feedApple: false)
            }
            return
        }

        // Avoid double-installing the tap if OpenAI path already started Apple.
        if recognitionTask != nil, alongsideCapture {
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Locked / background: prefer on-device so we don't depend on network STT staying warm.
        request.requiresOnDeviceRecognition = preferOnDeviceRecognition && recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        var context = [
            "metformin", "AMPK", "gluconeogenesis", "vancomycin", "warfarin",
            "atorvastatin", "metoprolol", "lisinopril", "losartan", "spironolactone",
            "appendicitis", "ultrasound", "MRI", "CT", "pregnancy",
            "repeat", "skip", "pause", "explain", "I don't know"
        ]
        context.append(contentsOf: sttVocabularyHints)
        request.contextualStrings = Array(context.prefix(100))
        recognitionRequest = request

        // Start the recognition task BEFORE the mic tap so the first buffers
        // (and the first spoken word) aren't dropped on the floor.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppleRecognition(result: result, error: error)
            }
        }

        await installCaptureTap(feedApple: true)
    }

    private func installCaptureTap(feedApple: Bool) async {
        try? await configureAudioSession(bounce: false)
        audio.resumeKeepAliveAfterTTS()

        let inputNode = audio.inputNode
        // Soft reinstall — never reset/stop the shared engine (that kills keep-alive).
        if micTapInstalled {
            inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }

        var format = inputNode.inputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .error("Microphone format unavailable. Try toggling AirPods or Restart the review.")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureBuffer.append(buffer)
            if feedApple {
                self.recognitionRequest?.append(buffer)
            }
            if self.captureBuffer.lastPeak >= self.speechEnergyThreshold {
                Task { @MainActor in
                    self.markEnergySpeech()
                }
            }
        }
        micTapInstalled = true

        do {
            try audio.ensureEngineRunning()
        } catch {
            do {
                try await configureAudioSession(bounce: true)
                try audio.ensureEngineRunning()
            } catch {
                state = .error(friendlyAudioError(error))
            }
        }
    }

    private func removeMicTap() {
        guard micTapInstalled else { return }
        audio.inputNode.removeTap(onBus: 0)
        micTapInstalled = false
    }

    private func friendlyAudioError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.code == 561210739 || ns.localizedDescription.contains("561210739") {
            return "Audio session glitched (often AirPods after TTS). Tap Repeat, or toggle Bluetooth and try again."
        }
        return error.localizedDescription
    }

    private func startPCMPump() {
        pcmPumpTask?.cancel()
        pcmPumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, let client = self.realtimeClient, client.isConnected else { continue }
                // Realtime API expects 24 kHz PCM. Hardware is often 48 kHz — skip rather
                // than stream wrong-rate audio (which used to overwrite live captions).
                let rate = self.captureBuffer.sampleRate
                guard abs(rate - 24_000) < 50 else { continue }
                let (chunk, newOffset) = self.captureBuffer.pcmSince(offset: self.pcmStreamOffset)
                self.pcmStreamOffset = newOffset
                if !chunk.isEmpty {
                    client.appendPCM24k(chunk)
                }
            }
        }
    }

    /// Loud mic energy — used to know someone is talking, but must not keep
    /// resetting the end-of-turn clock on ambient hiss after they've stopped.
    private func markEnergySpeech() {
        let now = Date.now
        if !hasReceivedSpeech {
            hasReceivedSpeech = true
            firstSpeechDate = now
            lastSpeechDate = now
            return
        }
        // Only extend "still speaking" when energy is clearly above the noise floor.
        // Quiet room / AirPods idle sit near the threshold and used to prevent turn end.
        if captureBuffer.lastPeak >= speechEnergyThreshold * 1.35 {
            lastSpeechDate = now
        }
    }

    private func markTranscriptProgress(previous: String, next: String) {
        let now = Date.now
        if !hasReceivedSpeech {
            hasReceivedSpeech = true
            firstSpeechDate = now
        }
        let prevNorm = Self.normalizeTranscript(previous)
        let nextNorm = Self.normalizeTranscript(next)
        if nextNorm != prevNorm {
            lastSpeechDate = now
            lastTranscriptChangeDate = now
        } else if lastTranscriptChangeDate == nil {
            lastTranscriptChangeDate = now
            lastSpeechDate = lastSpeechDate ?? now
        }
    }

    private static func normalizeTranscript(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    func stopListening() async -> String {
        await finalizeListening(preferOpenAI: usingOpenAISTT)
    }

    func cancel() {
        speakGeneration += 1
        prefetchTask?.cancel()
        prefetchTask = nil
        finishListenTask?.cancel()
        finishListenTask = nil
        stopCurrentSpeech(resumeContinuation: true)
        cancelListeningPipeline(resumeListenContinuation: true)
        state = .idle
    }

    func pause() {
        if synthesizer.isSpeaking {
            synthesizer.pauseSpeaking(at: .word)
        }
        if let player = audioPlayer, player.isPlaying {
            player.pause()
        }
        // Soft-stop TTS node only — keep keep-alive for background audio entitlement.
        pcmPlayer?.stop()
        pcmPlayer = nil
        silenceTask?.cancel()
        state = .paused
        audio.resumeKeepAliveAfterTTS()
    }

    func resume() {
        Task {
            try? await audio.reassert()
        }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .speaking
            return
        }
        do {
            try audio.ensureEngineRunning()
            audio.startKeepAlive()
            if let max = remainingMaxDuration() {
                startSilenceMonitor(maxDuration: max)
            }
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    // MARK: - Recognition handlers

    private func handleAppleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                let previous = lastTranscript
                // Apple re-delivers the same partial while you pause — only treat
                // real caption growth as "still speaking" (OpenAI-style turn taking).
                markTranscriptProgress(previous: previous, next: text)
                partialTranscript = text
                lastTranscript = text
            }

            if result.isFinal, !usingOpenAISTT {
                Task { await finalizeListening(preferOpenAI: false) }
            }
        }

        if let error {
            let ns = error as NSError
            if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 || ns.code == 1101 {
                return
            }
            if listenContinuation != nil, !hasReceivedSpeech { return }
            if listenContinuation != nil, hasReceivedSpeech, !usingOpenAISTT {
                Task { await finalizeListening(preferOpenAI: false) }
            }
        }
    }

    private func startSilenceMonitor(maxDuration: TimeInterval) {
        silenceTask?.cancel()
        let started = listenStartedAt ?? .now

        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }

                let now = Date.now
                if now.timeIntervalSince(started) >= maxDuration {
                    await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                    return
                }

                let transcript = self.lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.hasReceivedSpeech, !transcript.isEmpty else { continue }

                let lastSpeech = self.lastSpeechDate ?? self.firstSpeechDate ?? now
                let firstSpeech = self.firstSpeechDate ?? lastSpeech
                let lastChange = self.lastTranscriptChangeDate ?? lastSpeech

                let spokenFor = lastSpeech.timeIntervalSince(firstSpeech)
                let quietFor = now.timeIntervalSince(lastSpeech)
                let stableFor = now.timeIntervalSince(lastChange)
                let isCommand = VoiceCommand.isCompleteCommand(transcript)

                if isCommand {
                    if stableFor >= self.commandSilenceTimeout || quietFor >= self.commandSilenceTimeout {
                        await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                        return
                    }
                    continue
                }

                // Primary: caption stopped changing (what users experience as "I finished").
                if stableFor >= self.transcriptStableTimeout {
                    await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                    return
                }

                // Secondary: clear mic quiet after we've heard something.
                if spokenFor >= self.minimumSpeechDuration, quietFor >= self.silenceTimeout {
                    await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                    return
                }
            }
        }
    }

    private func finalizeListening(preferOpenAI: Bool) async -> String {
        guard listenContinuation != nil else {
            return lastTranscript
        }
        // Prevent double finalize.
        let continuation = listenContinuation
        listenContinuation = nil
        silenceTask?.cancel()
        silenceTask = nil
        pcmPumpTask?.cancel()
        pcmPumpTask = nil
        state = .processing

        recognitionRequest?.endAudio()
        // Keep shared engine + keep-alive running through STT/grade (locked walks).
        removeMicTap()
        audio.resumeKeepAliveAfterTTS()

        // Start from Apple live text only — never prefer realtime (often wrong sample rate).
        var text = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        await realtimeClient?.commit()

        // When locked / inactive, skip OpenAI STT and trust Apple (often on-device).
        let allowCloudSTT = preferOpenAI && !preferOnDeviceRecognition
        if allowCloudSTT, let stt = settings.makeOpenAISTTProvider {
            let wav = captureBuffer.wavData
            let duration = captureBuffer.durationSeconds
            if duration >= 0.2, wav.count > 2_000 {
                let prompt = OpenAITranscriptionProvider.prompt(
                    cardQuestion: sttQuestionHint,
                    expectedAnswer: sttExpectedAnswerHint,
                    extraTerms: sttVocabularyHints
                )
                do {
                    let precise = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await stt.transcribe(wavData: wav, prompt: prompt)
                        }
                        group.addTask {
                            try await Task.sleep(for: .milliseconds(2_400))
                            throw CancellationError()
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    if !precise.isEmpty {
                        text = precise
                    }
                } catch {
                    // Keep Apple transcript.
                }
            }
        }

        realtimeClient?.close()
        realtimeClient = nil
        tearDownRecognitionHandles()

        lastTranscript = text
        partialTranscript = text
        state = .idle
        continuation?.resume(returning: text)
        return text
    }

    private func cancelListeningPipeline(resumeListenContinuation: Bool) {
        silenceTask?.cancel()
        silenceTask = nil
        pcmPumpTask?.cancel()
        pcmPumpTask = nil
        finishListenTask?.cancel()
        finishListenTask = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        realtimeClient?.close()
        realtimeClient = nil

        removeMicTap()
        // Do not stop the shared engine — keep-alive must survive cancel mid-turn.

        if resumeListenContinuation, let continuation = listenContinuation {
            listenContinuation = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private func tearDownRecognitionHandles() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func remainingMaxDuration() -> TimeInterval? {
        guard let started = listenStartedAt else { return 28 }
        return max(1, 28 - Date.now.timeIntervalSince(started))
    }

    private func preferredEnglishVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let enhanced = voices.first(where: { $0.quality == .enhanced && $0.language == "en-US" }) {
            return enhanced
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Interruptions / route changes

    private func installSessionObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            wasSpeakingAtInterruption = (state == .speaking)
            pause()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    try? await self.audio.reassert()
                    if self.wasSpeakingAtInterruption {
                        // PCM can't resume mid-stream — ask the session to re-speak the card.
                        self.promptReplayRequested = true
                        self.wasSpeakingAtInterruption = false
                        self.state = .idle
                    } else {
                        self.resume()
                    }
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            Task { @MainActor in
                let wasSpeaking = self.state == .speaking
                try? await self.audio.reassert()
                if wasSpeaking {
                    self.promptReplayRequested = true
                    self.stopCurrentSpeech(resumeContinuation: true)
                } else if self.state == .listening {
                    try? self.audio.ensureEngineRunning()
                    self.audio.startKeepAlive()
                    if !self.micTapInstalled {
                        await self.installCaptureTap(feedApple: self.recognitionRequest != nil)
                    }
                }
            }
        }
    }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if let continuation = self.speechContinuation {
                self.speechContinuation = nil
                self.state = .idle
                continuation.resume()
            }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            if let continuation = self.speechContinuation {
                self.speechContinuation = nil
                self.state = .idle
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

extension VoiceManager: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.audioPlayer else { return }
            self.audioPlayer = nil
            if let continuation = self.speechContinuation {
                self.speechContinuation = nil
                self.state = .idle
                continuation.resume()
            }
        }
    }
}
