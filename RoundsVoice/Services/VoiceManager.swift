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
    /// Seconds from mic-ready → first real transcribed words (for Easy/Hard scoring).
    var lastResponseLatency: TimeInterval { get }

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
    /// Half-duplex: speak the full prompt, then earcon + listen for a transcript-only answer.
    func speakPromptAndCollectAnswer(prompt: String, maxDuration: TimeInterval) async throws -> String
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
    /// Mic-ready → first transcribed words. Used for Easy (fast) / Hard (slow) FSRS ratings.
    private(set) var lastResponseLatency: TimeInterval = 0

    /// Legacy energy quiet window — unused for end-of-turn (transcript-only).
    var silenceTimeout: TimeInterval = 2.0
    /// Short commands ("skip", "repeat") can finalize sooner once the caption is stable.
    var commandSilenceTimeout: TimeInterval = 0.7
    var minimumSpeechDuration: TimeInterval = 0.18
    /// No new transcribed words for this long → end of turn.
    var transcriptStableTimeout: TimeInterval = 2.0
    /// Peak above this counts as real speech energy (diagnostics / optional UI only).
    var speechEnergyThreshold: Float = 0.045
    /// Stronger peak — not used to auto-advance (volume / motion false triggers).
    var credibleSpeechPeak: Float = 0.06
    /// Ignore mic/captions briefly after arming (route switch settle after TTS → listen).
    var listenSettleDuration: TimeInterval = 0.35
    /// Minimum normalized caption length before we believe the user spoke.
    var minimumTranscriptCharacters: Int = 2

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
    /// True while the card prompt is still playing — silence monitor must not finalize yet.
    private var promptPlaybackActive = false
    private var didBargeIn = false
    /// Captions seen during settle are discarded so route noise can't auto-advance.
    private var listenSettleUntil: Date?
    private var answerListenOpenedAt: Date?
    private var firstAnswerTranscriptAt: Date?

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
        // Never flip category while a prompt is playing — causes TTS cutouts.
        if promptPlaybackActive || state == .speaking {
            try audio.ensureEngineRunning()
            return
        }
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
    private func prepareForListening(preserveSpeech: Bool = false) async throws {
        if !preserveSpeech {
            stopCurrentSpeech(resumeContinuation: false)
        }
        try await configureAudioSession(bounce: false)
        audio.pauseKeepAliveForListening()
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
        promptPlaybackActive = false
        didBargeIn = false
        stopCurrentSpeech(resumeContinuation: true)
        removeMicTap()
        speakGeneration += 1
        let generation = speakGeneration
        state = .speaking

        if let provider = settings.makeOpenAITTSProvider {
            do {
                try await speakWithOpenAI(text, provider: provider, generation: generation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One retry after a full session bounce — don't immediately dump to Siri.
                guard generation == speakGeneration else { throw CancellationError() }
                do {
                    try await audio.configureSession(bounce: true)
                    try await speakWithOpenAI(text, provider: provider, generation: generation)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard generation == speakGeneration else { throw CancellationError() }
                    try await audio.configureSession(bounce: false)
                    try await speakWithApple(text)
                }
            }
        } else {
            try await audio.configureSession(bounce: false)
            try await speakWithApple(text)
        }

        guard generation == speakGeneration else { throw CancellationError() }
        stopCurrentSpeech(resumeContinuation: false)
        audio.resumeKeepAliveAfterTTS()
    }

    /// Half-duplex walk loop (speaker, built-in mic, or AirPods):
    /// 1) Speak the full prompt on a stable output route (no mic / no barge-in)
    /// 2) Switch to listen (HFP / mic) + earcon = "your turn"
    /// 3) End turn after ~2s with no new transcribed words
    func speakPromptAndCollectAnswer(prompt: String, maxDuration: TimeInterval = 28) async throws -> String {
        cancelListeningPipeline(resumeListenContinuation: true)
        stopCurrentSpeech(resumeContinuation: true)
        removeMicTap()

        lastTranscript = ""
        partialTranscript = ""
        lastSpeechDate = nil
        firstSpeechDate = nil
        lastTranscriptChangeDate = nil
        hasReceivedSpeech = false
        lastResponseLatency = 0
        answerListenOpenedAt = nil
        firstAnswerTranscriptAt = nil
        listenStartedAt = .now
        listenSettleUntil = nil
        pcmStreamOffset = 0
        captureBuffer.reset()
        usingOpenAISTT = settings.shouldUseOpenAISTT
        didBargeIn = false
        promptPlaybackActive = true
        state = .speaking

        speakGeneration += 1
        let generation = speakGeneration

        // Phase 1 — speak only. Never arm the mic or flip BT profiles mid-utterance.
        do {
            if let provider = settings.makeOpenAITTSProvider {
                let key = provider.cacheKey(for: prompt, format: "pcm")
                if let cached = await TTSAudioCache.shared.data(for: key), cached.count > 256 {
                    try await playPCMData(cached, generation: generation)
                } else {
                    do {
                        try await speakWithOpenAI(prompt, provider: provider, generation: generation)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        guard generation == speakGeneration else { throw CancellationError() }
                        do {
                            try await audio.configureSession(bounce: true)
                            try await speakWithOpenAI(prompt, provider: provider, generation: generation)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            guard generation == speakGeneration else { throw CancellationError() }
                            try await audio.configureSession(bounce: false)
                            try await speakWithApple(prompt)
                        }
                    }
                }
            } else {
                try await audio.configureSession(bounce: false)
                try await speakWithApple(prompt)
            }
        } catch is CancellationError {
            promptPlaybackActive = false
            throw CancellationError()
        }

        guard generation == speakGeneration else {
            promptPlaybackActive = false
            throw CancellationError()
        }

        // Phase 2 — listen only. Route flip happens here, after TTS has fully finished.
        promptPlaybackActive = false
        stopCurrentSpeech(resumeContinuation: false)
        try await audio.prepareForListeningCapture()
        try await startListening(playReadyCue: true)
        answerListenOpenedAt = .now
        return try await awaitAnswer(maxDuration: maxDuration)
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
        try await player.start()

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
        try await player.start()
        // Schedule in larger chunks so the engine stays ahead of the playhead.
        let chunkSize = 9_600 // ~200 ms @ 24 kHz mono Int16
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
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
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

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
        try await startListening(playReadyCue: true)
    }

    func startListening(playReadyCue: Bool) async throws {
        cancelListeningPipeline(resumeListenContinuation: false)

        lastTranscript = ""
        partialTranscript = ""
        lastSpeechDate = nil
        firstSpeechDate = nil
        lastTranscriptChangeDate = nil
        hasReceivedSpeech = false
        listenStartedAt = .now
        listenSettleUntil = Date.now.addingTimeInterval(listenSettleDuration)
        pcmStreamOffset = 0
        captureBuffer.reset()
        usingOpenAISTT = settings.shouldUseOpenAISTT
        promptPlaybackActive = false
        didBargeIn = false
        state = .idle

        do {
            try await prepareForListening(preserveSpeech: false)

            if usingOpenAISTT {
                await startOpenAIListening()
            } else {
                try await startAppleListening()
            }

            guard audio.isEngineRunning || micTapInstalled else {
                throw VoiceError.audioEngineFailed("Microphone failed to start.")
            }
        } catch {
            // `prepareForListening` mutes/near-silences keep-alive before the mic is
            // proven to be running. If arming fails, never leave a locked session
            // stuck on that muted keep-alive — that silent gap is exactly what lets
            // iOS suspend the app mid-review.
            audio.resumeKeepAliveAfterTTS()
            throw error
        }

        // Drop any audio captured during engine restart / route flip.
        captureBuffer.reset()
        lastTranscript = ""
        partialTranscript = ""
        hasReceivedSpeech = false
        listenStartedAt = .now
        listenSettleUntil = Date.now.addingTimeInterval(listenSettleDuration)

        state = .listening
        signalMicReady(hapticOnly: !playReadyCue)
    }

    private func signalMicReady(hapticOnly: Bool) {
        if !hapticOnly {
            audio.playMicReadyEarcon()
        }
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: hapticOnly ? 0.4 : 0.55)
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
        // Avoid reconfigure+restart when the mic is already hot — that was the
        // multi-hundred-ms gap after every prompt.
        if micTapInstalled, audio.isEngineRunning {
            audio.pauseKeepAliveForListening()
            return
        }

        try? await configureAudioSession(bounce: false)
        audio.pauseKeepAliveForListening()

        let inputNode = audio.inputNode
        if micTapInstalled {
            inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }

        if inputNode.isVoiceProcessingEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(false)
            } catch {
                // Best-effort.
            }
        }

        var format = inputNode.inputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .error("Microphone format unavailable. Try toggling AirPods or Restart the review.")
            return
        }

        // Capture last hop time off-main; coalesce energy marks so we don't flood MainActor.
        let energyGate = EnergyHopGate()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureBuffer.append(buffer)
            if feedApple {
                self.recognitionRequest?.append(buffer)
            }
            if self.captureBuffer.lastPeak >= self.speechEnergyThreshold,
               energyGate.tryAdmit(minInterval: 0.045) {
                Task { @MainActor in
                    self.markEnergySpeech()
                }
            }
        }
        micTapInstalled = true

        do {
            try audio.restartEngine()
        } catch {
            do {
                try await configureAudioSession(bounce: true)
                try audio.restartEngine()
            } catch {
                state = .error(friendlyAudioError(error))
            }
        }
    }

    /// New Apple recognition request without tearing down the mic tap (post-prompt / barge-in).
    private func refreshRecognitionKeepingTap() async {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        guard let recognizer = speechRecognizer, recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
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
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppleRecognition(result: result, error: error)
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

    /// Mic energy is noisy (phone motion, volume buttons, AirPods hiss).
    /// Never use it to start a turn or barge in — only transcripts do that.
    private func markEnergySpeech() {
        // Intentionally ignored for turn-taking / barge-in.
        // Kept as a hook so the mic tap doesn't need a special-case branch.
        _ = captureBuffer.lastPeak
    }

    private func markTranscriptProgress(previous: String, next: String) {
        if isInListenSettle { return }
        let prevNorm = Self.normalizeTranscript(previous)
        let nextNorm = Self.normalizeTranscript(next)
        guard !nextNorm.isEmpty else { return }

        // Half-duplex: never barge in / cut TTS from captions.
        guard !promptPlaybackActive else { return }

        let now = Date.now
        // Only real caption changes count as "speech" for end-of-turn.
        if nextNorm != prevNorm {
            if !hasReceivedSpeech {
                hasReceivedSpeech = true
                firstSpeechDate = now
            }
            if firstAnswerTranscriptAt == nil, nextNorm.count >= minimumTranscriptCharacters {
                firstAnswerTranscriptAt = now
                if let opened = answerListenOpenedAt {
                    lastResponseLatency = max(0, now.timeIntervalSince(opened))
                }
            }
            lastSpeechDate = now
            lastTranscriptChangeDate = now
        } else if hasReceivedSpeech, lastTranscriptChangeDate == nil {
            lastTranscriptChangeDate = now
            lastSpeechDate = lastSpeechDate ?? now
        }
    }

    private var isInListenSettle: Bool {
        guard let until = listenSettleUntil else { return false }
        return Date.now < until
    }

    /// Transcript-only: never advance on energy / motion / volume spikes.
    private var heardCredibleUtterance: Bool {
        let transcript = Self.normalizeTranscript(lastTranscript)
        guard transcript.count >= minimumTranscriptCharacters else { return false }
        // Prefer a real word or a slightly longer token — reject single-letter STT noise.
        if transcript.count >= 3 { return true }
        return transcript.contains(" ")
    }

    // Half-duplex: barge-in removed. Prompt always plays to completion.

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
        if isInListenSettle {
            // Route/HFP settle produces junk partials — ignore until armed.
            return
        }

        if let result {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                let previous = lastTranscript
                markTranscriptProgress(previous: previous, next: text)
                partialTranscript = text
                lastTranscript = text
            }

            if result.isFinal, !usingOpenAISTT, heardCredibleUtterance {
                Task { await finalizeListening(preferOpenAI: false) }
            }
        }

        if let error {
            let ns = error as NSError
            if ns.domain == "kAFAssistantErrorDomain", ns.code == 1110 || ns.code == 1101 {
                return
            }
            if listenContinuation != nil, !hasReceivedSpeech { return }
            if listenContinuation != nil, heardCredibleUtterance, !usingOpenAISTT {
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
                    // Timed out with no real speech → empty answer (don't hallucinate).
                    await self.finalizeListening(preferOpenAI: self.heardCredibleUtterance && self.usingOpenAISTT)
                    return
                }

                if self.promptPlaybackActive { continue }
                if self.isInListenSettle { continue }

                // Transcript-only end-of-turn: no words → never finalize early.
                guard self.heardCredibleUtterance else { continue }
                let transcript = Self.normalizeTranscript(self.lastTranscript)
                guard !transcript.isEmpty else { continue }

                guard let lastChange = self.lastTranscriptChangeDate else { continue }
                let stableFor = now.timeIntervalSince(lastChange)
                let isCommand = VoiceCommand.isCompleteCommand(transcript)

                if isCommand {
                    if stableFor >= self.commandSilenceTimeout {
                        await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                        return
                    }
                    continue
                }

                // Natural pause: ~2s with no new transcribed words → move on.
                if stableFor >= self.transcriptStableTimeout {
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
        let continuation = listenContinuation
        listenContinuation = nil
        silenceTask?.cancel()
        silenceTask = nil
        pcmPumpTask?.cancel()
        pcmPumpTask = nil
        state = .processing

        recognitionRequest?.endAudio()
        removeMicTap()
        try? audio.restartEngine()
        audio.resumeKeepAliveAfterTTS()

        var text = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heardCredibleUtterance {
            // No real utterance — return empty so the session asks again instead of auto-grading.
            text = ""
            await realtimeClient?.commit()
            realtimeClient?.close()
            realtimeClient = nil
            tearDownRecognitionHandles()
            lastTranscript = ""
            partialTranscript = ""
            state = .idle
            continuation?.resume(returning: "")
            return ""
        }

        await realtimeClient?.commit()

        let allowCloudSTT = preferOpenAI && !preferOnDeviceRecognition
        let strongMic = captureBuffer.maxPeak >= credibleSpeechPeak
        let appleHasText = !text.isEmpty
        // Only call cloud STT when we actually captured speech. Quiet WAVs + answer
        // prompts made gpt-4o-transcribe invent the expected answer.
        if allowCloudSTT, strongMic || appleHasText, let stt = settings.makeOpenAISTTProvider {
            let wav = captureBuffer.wavData
            let duration = captureBuffer.durationSeconds
            if duration >= 0.35, wav.count > 4_000, strongMic {
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
                    let cleaned = precise.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty, !Self.looksLikePromptHallucination(cleaned, expected: sttExpectedAnswerHint, apple: text) {
                        text = cleaned
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

    /// If Apple heard nothing meaningful but cloud STT returns the exact expected answer, reject it.
    private static func looksLikePromptHallucination(_ cloud: String, expected: String, apple: String) -> Bool {
        let cloudNorm = normalizeTranscript(cloud)
        let expectedNorm = normalizeTranscript(expected)
        let appleNorm = normalizeTranscript(apple)
        guard !expectedNorm.isEmpty, !cloudNorm.isEmpty else { return false }
        let appleWeak = appleNorm.count < 2
        let matchesExpected = cloudNorm == expectedNorm
            || expectedNorm.contains(cloudNorm)
            || cloudNorm.contains(expectedNorm)
        return appleWeak && matchesExpected
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
        audio.resumeKeepAliveAfterTTS()

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

/// Thread-safe rate gate for mic-tap → MainActor hops.
private final class EnergyHopGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastAdmit: CFAbsoluteTime = 0

    func tryAdmit(minInterval: CFAbsoluteTime) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        guard now - lastAdmit >= minInterval else { return false }
        lastAdmit = now
        return true
    }
}
