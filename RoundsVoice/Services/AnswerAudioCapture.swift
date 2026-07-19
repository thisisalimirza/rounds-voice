import AVFoundation
import Foundation

/// Captures mic buffers as mono Int16 PCM and builds a WAV for OpenAI transcription.
/// Avoids `AVAudioConverter` (often fails silently across AirPods / hardware format changes).
final class AnswerAudioCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = Data()
    private(set) var sampleRate: Double = 24_000
    private(set) var lastPeak: Float = 0
    private(set) var maxPeak: Float = 0

    var durationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        let frameCount = samples.count / MemoryLayout<Int16>.size
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / sampleRate
    }

    var byteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples.count
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lastPeak = 0
        maxPeak = 0
        sampleRate = 24_000
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        sampleRate = buffer.format.sampleRate

        var peak: Float = 0
        samples.reserveCapacity(samples.count + frames * 2)

        if let floatChannels = buffer.floatChannelData {
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels {
                    sum += floatChannels[ch][i]
                }
                let sample = max(-1, min(1, sum / Float(channels)))
                peak = max(peak, abs(sample))
                var intSample = Int16(sample * Float(Int16.max - 1))
                withUnsafeBytes(of: &intSample) { samples.append(contentsOf: $0) }
            }
        } else if let intChannels = buffer.int16ChannelData {
            for i in 0..<frames {
                var sum = 0
                for ch in 0..<channels {
                    sum += Int(intChannels[ch][i])
                }
                let averaged = max(Int(Int16.min), min(Int(Int16.max), sum / channels))
                peak = max(peak, abs(Float(averaged) / Float(Int16.max)))
                var intSample = Int16(averaged)
                withUnsafeBytes(of: &intSample) { samples.append(contentsOf: $0) }
            }
        } else {
            return
        }

        lastPeak = peak
        maxPeak = max(maxPeak, peak)
    }

    /// PCM slice for realtime streaming (may be native rate — realtime expects 24 kHz;
    /// only use when sampleRate ≈ 24000, otherwise skip realtime append).
    func pcmSince(offset: Int) -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard offset < samples.count else { return (Data(), samples.count) }
        let aligned = offset - (offset % 2)
        return (samples.subdata(in: aligned..<samples.count), samples.count)
    }

    var wavData: Data {
        lock.lock()
        let pcm = samples
        let rate = Int(sampleRate.rounded())
        lock.unlock()
        return Self.wrapWAV(pcmData: pcm, sampleRate: max(8_000, rate), channels: 1, bitsPerSample: 16)
    }

    private static func wrapWAV(pcmData: Data, sampleRate: Int, channels: Int, bitsPerSample: Int) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36 + pcmData.count)

        func append(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }

        append("RIFF")
        appendUInt32(riffSize)
        append("WAVE")
        append("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        append("data")
        appendUInt32(dataSize)
        data.append(pcmData)
        return data
    }
}
