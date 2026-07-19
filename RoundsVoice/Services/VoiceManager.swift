import AVFoundation
import Foundation
import Speech

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

    func configureAudioSession() throws
    func requestPermissions() async -> Bool
    func speak(_ text: String) async throws
    func prefetchSpeech(_ text: String)
    func listenForAnswer(maxDuration: TimeInterval) async throws -> String
    func startListening() async throws
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

    var silenceTimeout: TimeInterval = 1.55
    var commandSilenceTimeout: TimeInterval = 0.45
    var minimumSpeechDuration: TimeInterval = 0.35
    /// RMS peak above this counts as speech for energy VAD (OpenAI path).
    var speechEnergyThreshold: Float = 0.025

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var pcmPlayer: PCMStreamPlayer?
    private var speechContinuation: CheckedContinuation<Void, Error>?
    private var speakGeneration = 0
    private var settings: AppSettings

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let captureBuffer = PCM24kCaptureBuffer()
    private var realtimeClient: RealtimeTranscriptionClient?
    private var pcmStreamOffset = 0
    private var usingOpenAISTT = false

    private var silenceTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var pcmPumpTask: Task<Void, Never>?
    private var listenContinuation: CheckedContinuation<String, Error>?
    private var lastSpeechDate: Date?
    private var firstSpeechDate: Date?
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

    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Tear down any prior activation so AirPods / dual-engine handoffs don't hit !ses (expired session).
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .duckOthers
            ]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try? session.overrideOutputAudioPort(.speaker)
    }

    /// Stop TTS playback engines and refresh the session before microphone use.
    private func prepareForListening() throws {
        stopCurrentSpeech(resumeContinuation: false)
        // Give hardware a beat after PCM engine teardown (especially with AirPods).
        // Caller may await a short sleep after this.
        try configureAudioSession()
    }

    func requestPermissions() async -> Bool {
        let micGranted = await AVAudioApplication.requestRecordPermission()
        let speechGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        // Mic is required; Apple Speech is only needed for offline fallback.
        return micGranted && (settings.shouldUseOpenAISTT || speechGranted)
    }

    // MARK: - Text to speech

    func speak(_ text: String) async throws {
        cancelListeningPipeline(resumeListenContinuation: true)
        stopCurrentSpeech(resumeContinuation: true)
        speakGeneration += 1
        let generation = speakGeneration
        state = .speaking

        try configureAudioSession()

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
        // Hand off cleanly to the mic path (prevents OSStatus !ses / expired session with AirPods).
        stopCurrentSpeech(resumeContinuation: false)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try await Task.sleep(for: .milliseconds(120))
        try configureAudioSession()
        try await Task.sleep(for: .milliseconds(100))
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
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.12

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
        return try await withCheckedThrowingContinuation { continuation in
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
        hasReceivedSpeech = false
        listenStartedAt = .now
        pcmStreamOffset = 0
        captureBuffer.reset()
        usingOpenAISTT = settings.shouldUseOpenAISTT
        state = .listening

        try prepareForListening()
        try await Task.sleep(for: .milliseconds(60))

        if usingOpenAISTT {
            await startOpenAIListening()
        } else {
            try startAppleListening()
        }
    }

    private func startOpenAIListening() async {
        // Live captions via realtime; final answer via gpt-4o-transcribe on captured WAV.
        let client = RealtimeTranscriptionClient()
        realtimeClient = client
        client.onPartial = { [weak self] text in
            guard let self else { return }
            self.partialTranscript = text
            self.lastTranscript = text
            self.markSpeechActivity()
        }
        client.onSpeechActivity = { [weak self] in
            self?.markSpeechActivity()
        }

        if let provider = settings.makeOpenAISTTProvider {
            try? await client.connect(apiKey: provider.apiKey, projectID: provider.projectID)
        }

        // Always keep Apple as live caption backup if realtime isn't up.
        if !client.isConnected {
            try? startAppleListening(alongsideCapture: true)
        } else {
            installCaptureTap(feedApple: false)
        }

        startPCMPump()
    }

    private func startAppleListening(alongsideCapture: Bool = false) throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            if !alongsideCapture && !usingOpenAISTT {
                state = .error("Recognizer unavailable")
                throw VoiceError.recognizerUnavailable
            }
            if !alongsideCapture {
                installCaptureTap(feedApple: false)
            }
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = [
            "metformin", "AMPK", "gluconeogenesis", "vancomycin", "warfarin",
            "atorvastatin", "metoprolol", "lisinopril", "losartan", "spironolactone",
            "repeat", "skip", "pause", "explain", "I don't know"
        ]
        recognitionRequest = request

        installCaptureTap(feedApple: true)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                self.handleAppleRecognition(result: result, error: error)
            }
        }
    }

    private func installCaptureTap(feedApple: Bool) {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.captureBuffer.append(buffer)
            if feedApple {
                self.recognitionRequest?.append(buffer)
            }
            // Energy VAD for OpenAI path (and as supplement).
            if self.captureBuffer.lastPeak >= self.speechEnergyThreshold {
                Task { @MainActor in
                    self.markSpeechActivity()
                }
            }
        }

        do {
            audioEngine.prepare()
            if !audioEngine.isRunning {
                try configureAudioSession()
                try audioEngine.start()
            }
        } catch {
            // Retry once after a full session bounce — common with AirPods after TTS.
            do {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                try configureAudioSession()
                audioEngine.prepare()
                try audioEngine.start()
            } catch {
                state = .error(friendlyAudioError(error))
            }
        }
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
                let (chunk, newOffset) = self.captureBuffer.pcmSince(offset: self.pcmStreamOffset)
                self.pcmStreamOffset = newOffset
                if !chunk.isEmpty {
                    client.appendPCM24k(chunk)
                }
            }
        }
    }

    private func markSpeechActivity() {
        let now = Date.now
        if !hasReceivedSpeech {
            hasReceivedSpeech = true
            firstSpeechDate = now
        }
        lastSpeechDate = now
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
        pcmPlayer?.stop()
        if audioEngine.isRunning {
            audioEngine.pause()
        }
        silenceTask?.cancel()
        state = .paused
    }

    func resume() {
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            state = .speaking
            return
        }
        do {
            try audioEngine.start()
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
                // Don't overwrite a richer OpenAI realtime caption unless Apple is the only source.
                if realtimeClient?.isConnected != true {
                    partialTranscript = text
                    lastTranscript = text
                } else if partialTranscript.isEmpty {
                    partialTranscript = text
                    lastTranscript = text
                }
                markSpeechActivity()
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
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }

                let now = Date.now
                if now.timeIntervalSince(started) >= maxDuration {
                    await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                    return
                }

                guard self.hasReceivedSpeech,
                      let lastSpeech = self.lastSpeechDate,
                      let firstSpeech = self.firstSpeechDate
                else { continue }

                let spokenFor = lastSpeech.timeIntervalSince(firstSpeech)
                let silentFor = now.timeIntervalSince(lastSpeech)
                let isCommand = VoiceCommand.isCompleteCommand(self.lastTranscript)

                if isCommand {
                    if silentFor >= self.commandSilenceTimeout {
                        await self.finalizeListening(preferOpenAI: self.usingOpenAISTT)
                        return
                    }
                } else if spokenFor >= self.minimumSpeechDuration,
                          silentFor >= self.silenceTimeout {
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
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        var text = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if preferOpenAI, let stt = settings.makeOpenAISTTProvider {
            await realtimeClient?.commit()
            if let live = realtimeClient?.latestTranscript, !live.isEmpty {
                text = live
                partialTranscript = live
            }

            let wav = captureBuffer.wavData
            do {
                let precise = try await stt.transcribe(wavData: wav)
                if !precise.isEmpty {
                    text = precise
                }
            } catch {
                // Keep realtime / Apple transcript.
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

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

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
            pause()
        case .ended:
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            if options.contains(.shouldResume) {
                try? configureAudioSession()
                resume()
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

        guard state != .speaking else { return }

        if reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            try? configureAudioSession()
            if state == .listening, !audioEngine.isRunning {
                try? audioEngine.start()
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
