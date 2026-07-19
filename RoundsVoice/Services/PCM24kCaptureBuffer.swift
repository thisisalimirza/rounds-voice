import AVFoundation
import Foundation

/// Collects mic audio as 24 kHz mono PCM and builds WAV for OpenAI transcription.
final class PCM24kCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = Data()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    /// Peak absolute sample (0…1) from the last append — used for energy VAD.
    private(set) var lastPeak: Float = 0

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        lastPeak = 0
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let format = buffer.format

        lock.lock()
        defer { lock.unlock() }

        if sourceFormat?.sampleRate != format.sampleRate
            || sourceFormat?.channelCount != format.channelCount {
            sourceFormat = format
            converter = AVAudioConverter(from: format, to: targetFormat)
        }

        guard let converter else { return }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        converter.convert(to: out, error: &error, withInputFrom: inputBlock)
        guard error == nil, out.frameLength > 0, let channels = out.int16ChannelData else { return }

        let frameCount = Int(out.frameLength)
        let pointer = channels[0]
        var peak: Int16 = 0
        for i in 0..<frameCount {
            let s = pointer[i]
            let a = s == Int16.min ? Int16.max : abs(s)
            if a > peak { peak = a }
        }
        lastPeak = Float(peak) / Float(Int16.max)

        samples.append(Data(bytes: pointer, count: frameCount * MemoryLayout<Int16>.size))
    }

    var pcmData: Data {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    var wavData: Data {
        let pcm = pcmData
        return Self.wrapWAV(pcmData: pcm, sampleRate: 24_000, channels: 1, bitsPerSample: 16)
    }

    /// Latest chunk of PCM since `from` byte offset (for realtime streaming).
    func pcmSince(offset: Int) -> (Data, Int) {
        lock.lock()
        defer { lock.unlock() }
        guard offset < samples.count else { return (Data(), samples.count) }
        // Align to Int16.
        let aligned = offset - (offset % 2)
        let slice = samples.subdata(in: aligned..<samples.count)
        return (slice, samples.count)
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
        appendUInt16(1) // PCM
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
