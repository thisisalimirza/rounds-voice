import AVFoundation
import Foundation

/// Plays OpenAI TTS PCM (24 kHz, 16-bit signed LE mono) on the shared review engine.
/// Does **not** stop the shared engine — keep-alive must stay alive for locked walks.
@MainActor
final class PCMStreamPlayer {
    private let sampleRate: Double
    private let format: AVAudioFormat
    private var scheduledBuffers = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let audio = ContinuousAudioSession.shared

    init(sampleRate: Double = OpenAITTSProvider.pcmSampleRate) {
        self.sampleRate = sampleRate
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func start() throws {
        audio.pauseKeepAliveForTTS()
        try audio.ensureEngineRunning()
        let player = audio.ttsPlayer
        if player.isPlaying {
            player.stop()
            player.reset()
        }
        // Reconnect if sample rate differs (OpenAI is 24 kHz).
        audio.engine.connect(player, to: audio.engine.mainMixerNode, format: format)
        player.play()
        scheduledBuffers = 0
    }

    func schedulePCM(_ data: Data) {
        guard !data.isEmpty, let buffer = Self.makeBuffer(from: data, format: format) else { return }
        scheduledBuffers += 1
        audio.ttsPlayer.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.maybeFinish()
            }
        }
    }

    /// Call when no more chunks will arrive; waits until queued audio drains.
    func finishAndWait() async {
        if scheduledBuffers == 0 {
            softStop()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.finishContinuation = continuation
            self.maybeFinish()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if self.finishContinuation != nil {
                    self.completeFinish()
                }
            }
        }
        softStop()
    }

    /// Stops TTS playback only — leaves the shared engine and keep-alive intact.
    func stop() {
        softStop()
        completeFinish()
    }

    private func softStop() {
        let player = audio.ttsPlayer
        if player.isPlaying { player.stop() }
        player.reset()
        scheduledBuffers = 0
        audio.resumeKeepAliveAfterTTS()
    }

    private func maybeFinish() {
        guard finishContinuation != nil, scheduledBuffers == 0 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            self.completeFinish()
        }
    }

    private func completeFinish() {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume()
    }

    private static func makeBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channel = buffer.floatChannelData?[0] else { return nil }

        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                channel[i] = Float(base[i]) / Float(Int16.max)
            }
        }
        return buffer
    }
}
