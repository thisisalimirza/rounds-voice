import AVFoundation
import Foundation

/// Plays OpenAI TTS PCM (24 kHz, 16-bit signed LE mono) via AVAudioEngine, including streamed chunks.
@MainActor
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double
    private var format: AVAudioFormat
    private var isStarted = false
    private var scheduledBuffers = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var didFinish = false

    init(sampleRate: Double = OpenAITTSProvider.pcmSampleRate) {
        self.sampleRate = sampleRate
        self.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        guard !isStarted else { return }
        engine.prepare()
        try engine.start()
        player.play()
        isStarted = true
        didFinish = false
    }

    func schedulePCM(_ data: Data) {
        guard !data.isEmpty, let buffer = Self.makeBuffer(from: data, format: format) else { return }
        scheduledBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.maybeFinish()
            }
        }
    }

    /// Call when no more chunks will arrive; waits until queued audio drains.
    func finishAndWait() async {
        if scheduledBuffers == 0, !player.isPlaying {
            stop()
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.finishContinuation = continuation
            self.maybeFinish()
            // Watchdog if callbacks stall.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                if self.finishContinuation != nil {
                    self.completeFinish()
                }
            }
        }
        stop()
    }

    func stop() {
        if player.isPlaying { player.stop() }
        player.reset()
        if engine.isRunning { engine.stop() }
        engine.reset()
        isStarted = false
        scheduledBuffers = 0
        completeFinish()
    }

    private func maybeFinish() {
        guard finishContinuation != nil, scheduledBuffers == 0 else { return }
        // Tiny delay so the last buffer fully leaves the hardware.
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
