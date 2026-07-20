import AVFoundation
import Foundation
import UIKit

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
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Re-assert session without tearing down (lock → unlock, route blip).
    /// Never call while TTS is draining — `setCategory` mid-utterance causes cutouts.
    func reassert(allowDuringTTS: Bool = false) async throws {
        guard isReviewActive else { return }
        if !allowDuringTTS, ttsPlayer.isPlaying {
            try ensureEngineRunning()
            return
        }
        try await configureSession(bounce: false)
        try ensureEngineRunning()
        if !keepAliveRunning {
            startKeepAlive()
        }
    }

    /// True when the current route is any Bluetooth headset profile.
    var isBluetoothRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    // MARK: - Session

    /// Prep output for OpenAI TTS. Keeps `.playAndRecord` (mic tap must be off) and
    /// prefers A2DP via `.allowBluetoothA2DP` — switching to pure `.playback` was
    /// killing the audio graph (IPCAUClient -66748) and forcing Apple/Siri fallback.
    func prepareForTTSPlayback() async throws {
        if engine.isRunning {
            engine.stop()
        }
        ttsPlayer.stop()
        if keepAlivePlayer.isPlaying {
            keepAlivePlayer.pause()
        }

        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            let usingBluetooth = outputs.contains {
                [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
            }

            if usingBluetooth {
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.allowBluetoothA2DP, .allowBluetooth, .duckOthers]
                )
                try? session.overrideOutputAudioPort(.none)
            } else {
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetooth, .duckOthers]
                )
                try? session.overrideOutputAudioPort(.speaker)
            }
            try session.setActive(true, options: [])
        }.value

        try restartEngine()
    }

    /// Mic / HFP path for listening — half-duplex only: call after TTS fully finishes.
    /// This is the intentional A2DP → HFP flip (safe because nothing is speaking).
    func prepareForListeningCapture() async throws {
        if engine.isRunning {
            engine.stop()
        }
        ttsPlayer.stop()

        try await configureSession(bounce: false)
        try restartEngine()
    }

    /// Listen-route session (HFP on Bluetooth). Never call while TTS is playing.
    func configureSession(bounce: Bool) async throws {
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            let outputs = session.currentRoute.outputs
            let usingBluetooth = outputs.contains {
                [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
            }

            if usingBluetooth {
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.allowBluetooth, .duckOthers]
                )
            } else {
                try session.setCategory(
                    .playAndRecord,
                    mode: .spokenAudio,
                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers]
                )
            }

            if bounce {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
            }
            try session.setActive(true, options: [])

            if usingBluetooth {
                try? session.overrideOutputAudioPort(.none)
            } else {
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
        // Touch input early so the hardware format exists before we start keep-alive.
        _ = engine.inputNode
        engine.attach(ttsPlayer)
        engine.attach(keepAlivePlayer)
        engine.attach(earconPlayer)
        engine.connect(ttsPlayer, to: engine.mainMixerNode, format: keepAliveFormat)
        engine.connect(keepAlivePlayer, to: engine.mainMixerNode, format: keepAliveFormat)
        engine.connect(earconPlayer, to: engine.mainMixerNode, format: keepAliveFormat)
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

    /// Required after installing/removing an input tap on an already-running engine —
    /// otherwise the tap often receives zero buffers and STT stays empty.
    /// Does not restart keep-alive playback (caller decides — muted during listen).
    func restartEngine() throws {
        buildGraphIfNeeded()
        if engine.isRunning {
            engine.stop()
        }
        engine.prepare()
        try engine.start()
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
        keepAlivePlayer.volume = 0
        if keepAlivePlayer.isPlaying {
            keepAlivePlayer.pause()
        }
    }

    /// Stop keep-alive while the mic is open — recording keeps the session alive,
    /// and a looping tone can poison STT (AEC / energy threshold since the input
    /// tap runs with voice processing disabled).
    ///
    /// While the app is foregrounded we still fully mute/pause for best STT quality.
    /// While locked/backgrounded, a stalled recognizer or a route hiccup between
    /// mic-tap install and the first captured buffer is exactly the kind of silent
    /// gap that lets iOS suspend the session — so we leave an ultra-quiet fallback
    /// tone running as a backstop instead of going fully silent. The tradeoff (a
    /// faint echo leaking into the mic) is acceptable because locked walks already
    /// prefer on-device recognition (see `preferOnDeviceRecognition`), which is far
    /// less sensitive to that than cloud STT.
    func pauseKeepAliveForListening() {
        guard isAppActive else {
            keepAlivePlayer.volume = 0.0004
            if !keepAlivePlayer.isPlaying {
                keepAlivePlayer.play()
            }
            return
        }
        keepAlivePlayer.volume = 0
        if keepAlivePlayer.isPlaying {
            keepAlivePlayer.pause()
        }
    }

    private var isAppActive: Bool {
        UIApplication.shared.applicationState == .active
    }

    func resumeKeepAliveAfterTTS() {
        guard isReviewActive else { return }
        keepAlivePlayer.volume = 0.02
        if !keepAliveRunning {
            startKeepAlive()
            return
        }
        if !keepAlivePlayer.isPlaying {
            if let buffer = Self.nearSilentBuffer(format: keepAliveFormat, seconds: 1.0) {
                keepAlivePlayer.stop()
                keepAlivePlayer.scheduleBuffer(buffer, at: nil, options: [.loops])
            }
            keepAlivePlayer.play()
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
