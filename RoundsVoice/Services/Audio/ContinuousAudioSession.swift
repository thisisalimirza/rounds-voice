import AVFoundation
import Foundation

/// Keeps `AVAudioSession` + a shared `AVAudioEngine` alive for the whole review so
/// locked-screen / pocket walks don't get suspended between speak → listen → grade.
@MainActor
final class ContinuousAudioSession {
    static let shared = ContinuousAudioSession()

    let engine = AVAudioEngine()
    let ttsPlayer = AVAudioPlayerNode()
    let keepAlivePlayer = AVAudioPlayerNode()
    let earconPlayer = AVAudioPlayerNode()

    private(set) var isReviewActive = false
    private var keepAliveRunning = false
    private var graphBuilt = false
    private let keepAliveFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false
    )!

    private init() {}

    // MARK: - Review lifecycle

    func beginReview() async throws {
        isReviewActive = true
        try await configureSession(bounce: false)
        buildGraphIfNeeded()
        try ensureEngineRunning()
        startKeepAlive()
    }

    func endReview() {
        isReviewActive = false
        stopKeepAlive()
        ttsPlayer.stop()
        earconPlayer.stop()
        if engine.isRunning {
            engine.stop()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Re-assert session without tearing down (lock → unlock, route blip).
    func reassert() async throws {
        guard isReviewActive else { return }
        try await configureSession(bounce: false)
        try ensureEngineRunning()
        if !keepAliveRunning {
            startKeepAlive()
        }
    }

    // MARK: - Session

    /// AirPods duplex: HFP via `.allowBluetooth` only — A2DP breaks the mic path.
    func configureSession(bounce: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [
                    .allowBluetooth,
                    .duckOthers
                ]
            )
            if bounce {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try session.setActive(true, options: [])

            let outputs = session.currentRoute.outputs
            let usingBluetooth = outputs.contains {
                [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
            }
            if usingBluetooth {
                try? session.overrideOutputAudioPort(.none)
            } else {
                // Phone speaker for non-BT walks / debugging.
                try? session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
                )
                try session.setActive(true, options: [])
                try? session.overrideOutputAudioPort(.speaker)
            }
        }.value
        if bounce {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Engine graph

    private func buildGraphIfNeeded() {
        guard !graphBuilt else { return }
        engine.attach(ttsPlayer)
        engine.attach(keepAlivePlayer)
        engine.attach(earconPlayer)
        engine.connect(ttsPlayer, to: engine.mainMixerNode, format: keepAliveFormat)
        engine.connect(keepAlivePlayer, to: engine.mainMixerNode, format: keepAliveFormat)
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: keepAliveFormat)
        // Slightly duck keep-alive under real TTS.
        engine.mainMixerNode.outputVolume = 1.0
        graphBuilt = true
    }

    func ensureEngineRunning() throws {
        buildGraphIfNeeded()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !ttsPlayer.isPlaying { ttsPlayer.play() }
        if !earconPlayer.isPlaying { earconPlayer.play() }
    }

    var inputNode: AVAudioInputNode { engine.inputNode }

    var isEngineRunning: Bool { engine.isRunning }

    // MARK: - Keep-alive (prevents background suspend)

    func startKeepAlive() {
        guard isReviewActive else { return }
        buildGraphIfNeeded()
        try? ensureEngineRunning()
        guard !keepAliveRunning else {
            if !keepAlivePlayer.isPlaying { keepAlivePlayer.play() }
            return
        }
        keepAliveRunning = true
        keepAlivePlayer.volume = 0.02
        if !keepAlivePlayer.isPlaying { keepAlivePlayer.play() }
        guard let buffer = Self.nearSilentBuffer(format: keepAliveFormat, seconds: 1.0) else { return }
        keepAlivePlayer.scheduleBuffer(buffer, at: nil, options: [.loops])
    }

    func pauseKeepAliveForTTS() {
        keepAlivePlayer.volume = 0.001
    }

    func resumeKeepAliveAfterTTS() {
        guard isReviewActive else { return }
        keepAlivePlayer.volume = 0.02
        if !keepAliveRunning {
            startKeepAlive()
        } else if !keepAlivePlayer.isPlaying {
            keepAlivePlayer.play()
            if let buffer = Self.nearSilentBuffer(format: keepAliveFormat, seconds: 1.0) {
                keepAlivePlayer.scheduleBuffer(buffer, at: nil, options: [.loops])
            }
        }
    }

    func stopKeepAlive() {
        keepAliveRunning = false
        keepAlivePlayer.stop()
        keepAlivePlayer.reset()
    }

    // MARK: - Earcon (pocket “mic ready”)

    func playMicReadyEarcon() {
        guard let buffer = Self.toneBuffer(frequency: 880, duration: 0.07, format: keepAliveFormat) else {
            return
        }
        try? ensureEngineRunning()
        earconPlayer.volume = 0.35
        if !earconPlayer.isPlaying { earconPlayer.play() }
        earconPlayer.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Buffer helpers

    private static func nearSilentBuffer(format: AVAudioFormat, seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        // Inaudible but non-zero so the audio server stays busy.
        for i in 0..<Int(frames) {
            channel[i] = 0.0004 * sin(Float(i) * 0.02)
        }
        return buffer
    }

    private static func toneBuffer(frequency: Double, duration: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let sr = format.sampleRate
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let envelope = Float(min(1, t * 40) * min(1, (duration - t) * 40))
            channel[i] = envelope * 0.25 * sin(Float(2 * Double.pi * frequency * t))
        }
        return buffer
    }
}
