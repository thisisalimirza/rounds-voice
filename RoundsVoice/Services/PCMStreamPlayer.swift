import AVFoundation
import Foundation

/// Smooth OpenAI PCM playback on the shared engine.
/// Prebuffers before starting, schedules ahead of the playhead, and avoids
/// MainActor hops on every tiny network crumb (those caused underrun stutters).
@MainActor
final class PCMStreamPlayer {
    private let sampleRate: Double
    private let format: AVAudioFormat
    private var scheduledBuffers = 0
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private let audio = ContinuousAudioSession.shared

    /// Accumulate this much audio before the speaker starts (masks network jitter).
    private let prebufferBytes: Int
    /// Target chunk size once playing (~100 ms at 24 kHz mono Int16).
    private let scheduleChunkBytes: Int

    private var pending = Data()
    private var didStartPlayback = false
    private var acceptingData = true

    init(sampleRate: Double = OpenAITTSProvider.pcmSampleRate) {
        self.sampleRate = sampleRate
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        // ~280 ms prebuffer, ~100 ms schedule quanta.
        self.prebufferBytes = Int(sampleRate * 2 * 0.28)
        self.scheduleChunkBytes = Int(sampleRate * 2 * 0.10)
    }

    func start() async throws {
        acceptingData = true
        didStartPlayback = false
        pending.removeAll(keepingCapacity: true)
        scheduledBuffers = 0

        audio.pauseKeepAliveForTTS()
        try await audio.prepareForTTSPlayback()

        let player = audio.ttsPlayer
        if player.isPlaying {
            player.stop()
        }
        player.reset()
        // Reconnect after engine restart inside prepareForTTSPlayback.
        audio.engine.connect(player, to: audio.engine.mainMixerNode, format: format)
        scheduledBuffers = 0
    }

    func schedulePCM(_ data: Data) {
        guard acceptingData, data.count >= 2 else { return }
        pending.append(data)
        // Keep PCM 16-bit aligned.
        if pending.count % 2 == 1 {
            pending.removeLast()
        }
        flushPending(force: false)
    }

    /// Call when no more chunks will arrive; waits until queued audio drains.
    func finishAndWait() async {
        acceptingData = false
        flushPending(force: true)
        if !didStartPlayback {
            beginPlaybackIfNeeded(force: true)
            flushPending(force: true)
        }

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

    /// Stops TTS playback only — leaves the shared engine intact.
    func stop() {
        acceptingData = false
        softStop()
        completeFinish()
    }

    private func flushPending(force: Bool) {
        beginPlaybackIfNeeded(force: force)

        guard didStartPlayback else { return }

        let quanta = max(2, scheduleChunkBytes - (scheduleChunkBytes % 2))
        while pending.count >= quanta {
            let chunk = pending.prefix(quanta)
            pending.removeFirst(quanta)
            enqueue(Data(chunk))
        }
        if force, pending.count >= 2 {
            let aligned = pending.count - (pending.count % 2)
            let chunk = pending.prefix(aligned)
            pending.removeAll(keepingCapacity: true)
            enqueue(Data(chunk))
        }
    }

    private func beginPlaybackIfNeeded(force: Bool) {
        guard !didStartPlayback else { return }
        guard force || pending.count >= prebufferBytes else { return }
        didStartPlayback = true
        let player = audio.ttsPlayer
        if !audio.isEngineRunning {
            try? audio.ensureEngineRunning()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func enqueue(_ data: Data) {
        guard data.count >= 2 else { return }
        guard let buffer = Self.makeBuffer(from: data, format: format), buffer.frameLength > 0 else {
            return
        }
        scheduledBuffers += 1
        audio.ttsPlayer.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                self.maybeFinish()
            }
        }
    }

    private func softStop() {
        let player = audio.ttsPlayer
        if player.isPlaying { player.stop() }
        player.reset()
        scheduledBuffers = 0
        pending.removeAll(keepingCapacity: false)
        didStartPlayback = false
        acceptingData = false
    }

    private func maybeFinish() {
        guard finishContinuation != nil, scheduledBuffers == 0, !acceptingData, pending.isEmpty else { return }
        completeFinish()
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
