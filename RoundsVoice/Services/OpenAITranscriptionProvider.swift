import Foundation

enum STTProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case emptyAudio
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured for speech recognition."
        case .emptyAudio:
            return "No audio captured to transcribe."
        case .invalidResponse:
            return "Speech recognition returned an invalid response."
        case .httpError(let statusCode, let body):
            return "Speech recognition failed (\(statusCode)): \(body.prefix(200))"
        }
    }
}

/// Request-based OpenAI speech-to-text (`gpt-4o-transcribe`) for final medical answers.
struct OpenAITranscriptionProvider: Sendable {
    var apiKey: String
    var model: String
    var projectID: String
    var baseURL: URL

    init(
        apiKey: String,
        model: String = "gpt-4o-transcribe",
        projectID: String = "",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.projectID = projectID
        self.baseURL = baseURL
    }

    static let medicalPrompt = """
    Medical student answering Anki / AnKing flashcards aloud while walking. \
    Prefer correct drug names, anatomy, physiology, and abbreviations \
    (e.g. metformin, vancomycin, AMPK, gluconeogenesis, ACE inhibitor, ARB, NSAID, INR, D-Ala-D-Ala). \
    Voice commands may appear alone: repeat, skip, pause, explain, I don't know, idk. \
    Transcribe exactly what was said; keep medical spelling accurate.
    """

    func transcribe(wavData: Data, prompt: String = OpenAITranscriptionProvider.medicalPrompt) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw STTProviderError.missingAPIKey
        }
        guard wavData.count > 44 else { throw STTProviderError.emptyAudio }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let trimmedProject = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty {
            request.setValue(trimmedProject, forHTTPHeaderField: "OpenAI-Project")
        }
        request.timeoutInterval = 45

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", model)
        appendField("language", "en")
        appendField("response_format", "json")
        appendField("prompt", prompt)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"answer.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw STTProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw STTProviderError.httpError(statusCode: http.statusCode, body: bodyText)
        }

        if let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data),
           let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let plain = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            return plain
        }
        throw STTProviderError.invalidResponse
    }
}

private struct TranscriptionResponse: Decodable {
    var text: String?
}
