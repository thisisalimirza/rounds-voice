import Foundation

/// Text-to-speech backends for the review voice.
enum TTSEngine: String, CaseIterable, Identifiable, Sendable {
    case apple
    case openAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple system voice"
        case .openAI: return "Natural voice (OpenAI)"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: return "On-device · offline fallback"
        case .openAI: return "Cloud · streaming · most natural"
        }
    }
}

/// OpenAI TTS voices (gpt-4o-mini-tts).
enum OpenAITTSVoice: String, CaseIterable, Identifiable, Sendable {
    case marin
    case cedar
    case coral
    case sage
    case nova
    case ash
    case ballad
    case verse
    case alloy
    case echo
    case fable
    case onyx
    case shimmer

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var blurb: String {
        switch self {
        case .marin: return "Recommended · clearest overall quality"
        case .cedar: return "Recommended · warm & natural"
        case .coral: return "Warm · clear · tutoring tone"
        case .sage: return "Calm · steady · lecture-hall energy"
        case .nova: return "Bright · energetic"
        case .ash: return "Soft · understated"
        case .ballad: return "Smooth · storytelling"
        case .verse: return "Expressive · modern"
        case .alloy: return "Neutral · balanced"
        case .echo: return "Clear · mid-range"
        case .fable: return "British-leaning · narrative"
        case .onyx: return "Deeper · authoritative"
        case .shimmer: return "Light · airy"
        }
    }
}

enum TTSProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case emptyText
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured for natural voice."
        case .emptyText:
            return "Nothing to speak."
        case .invalidResponse:
            return "Natural voice returned an invalid audio response."
        case .httpError(let statusCode, let body):
            return "Natural voice failed (\(statusCode)): \(body.prefix(200))"
        case .playbackFailed:
            return "Couldn't play the synthesized voice audio."
        }
    }
}

/// Fetches audio from OpenAI `/v1/audio/speech` (full file or streamed PCM).
struct OpenAITTSProvider: Sendable {
    var apiKey: String
    var model: String
    var voice: OpenAITTSVoice
    var projectID: String
    var baseURL: URL
    var instructions: String
    var speed: Double

    /// OpenAI TTS PCM is 24 kHz, 16-bit signed LE mono.
    static let pcmSampleRate: Double = 24_000
    private static let maxInputCharacters = 4096

    init(
        apiKey: String,
        model: String = "gpt-4o-mini-tts",
        voice: OpenAITTSVoice = .marin,
        projectID: String = "",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        instructions: String = OpenAITTSProvider.defaultInstructions,
        speed: Double = 1.15
    ) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        self.projectID = projectID
        self.baseURL = baseURL
        self.instructions = instructions
        self.speed = min(4, max(0.25, speed))
    }

    static let defaultInstructions = """
    Speak briskly and clearly like a medical tutor on rounds. \
    Pronounce medical terms carefully. No filler sounds. Keep energy steady — not slow, not theatrical.
    """

    func cacheKey(for text: String, format: String = "pcm") -> String {
        TTSAudioCache.cacheKey(
            model: model,
            voice: voice.rawValue,
            speed: speed,
            text: "\(format)|\(text)"
        )
    }

    /// Full MP3 (used for prefetch / cache playback via AVAudioPlayer).
    func synthesizeMP3(text: String) async throws -> Data {
        try await synthesize(text: text, responseFormat: "mp3")
    }

    /// Full PCM buffer (24 kHz). Prefer `synthesizePCMStream` for lower time-to-first-audio.
    func synthesizePCM(text: String) async throws -> Data {
        try await synthesize(text: text, responseFormat: "pcm")
    }

    /// Streams PCM chunks as soon as OpenAI starts generating audio.
    func synthesizePCMStream(text: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { throw TTSProviderError.emptyText }
                    guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw TTSProviderError.missingAPIKey
                    }

                    var request = try makeSpeechRequest(
                        input: String(trimmed.prefix(Self.maxInputCharacters)),
                        responseFormat: "pcm"
                    )
                    request.timeoutInterval = 90

                    let (byteStream, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw TTSProviderError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var errorData = Data()
                        for try await byte in byteStream {
                            errorData.append(byte)
                            if errorData.count > 4_096 { break }
                        }
                        let bodyText = String(data: errorData, encoding: .utf8) ?? ""
                        throw TTSProviderError.httpError(statusCode: http.statusCode, body: bodyText)
                    }

                    // Read ~8 KB at a time (≈170 ms @ 24 kHz). Byte-by-byte iteration
                    // was a major source of scheduling jitter / underruns.
                    var buffer = Data()
                    buffer.reserveCapacity(16_384)
                    for try await byte in byteStream {
                        buffer.append(byte)
                        if buffer.count >= 8_192 {
                            // Keep 16-bit PCM frames aligned.
                            let aligned = buffer.count - (buffer.count % 2)
                            if aligned > 0 {
                                continuation.yield(Data(buffer.prefix(aligned)))
                                if aligned < buffer.count {
                                    buffer = Data(buffer.suffix(from: aligned))
                                } else {
                                    buffer.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                    }
                    if buffer.count >= 2 {
                        let aligned = buffer.count - (buffer.count % 2)
                        continuation.yield(Data(buffer.prefix(aligned)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func synthesize(text: String, responseFormat: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TTSProviderError.emptyText }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TTSProviderError.missingAPIKey
        }

        var request = try makeSpeechRequest(
            input: String(trimmed.prefix(Self.maxInputCharacters)),
            responseFormat: responseFormat
        )
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TTSProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TTSProviderError.httpError(statusCode: http.statusCode, body: bodyText)
        }
        guard data.count > 256 else {
            throw TTSProviderError.invalidResponse
        }
        return data
    }

    private func makeSpeechRequest(input: String, responseFormat: String) throws -> URLRequest {
        let endpoint = baseURL.appending(path: "audio/speech")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedProject = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty {
            request.setValue(trimmedProject, forHTTPHeaderField: "OpenAI-Project")
        }

        var body: [String: Any] = [
            "model": model,
            "input": input,
            "voice": voice.rawValue,
            "response_format": responseFormat,
            "speed": speed
        ]
        if model.contains("gpt-4o-mini-tts") || model.contains("gpt-4o-tts") {
            body["instructions"] = instructions
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
