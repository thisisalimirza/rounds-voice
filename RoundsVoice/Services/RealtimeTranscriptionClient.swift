import Foundation

/// Live captions via OpenAI Realtime transcription (`gpt-realtime-whisper`).
@MainActor
final class RealtimeTranscriptionClient: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var accumulated = ""
    private(set) var latestTranscript = ""
    private var isReady = false

    var onPartial: ((String) -> Void)?
    var onSpeechActivity: (() -> Void)?

    func connect(apiKey: String, projectID: String) async throws {
        close()
        accumulated = ""
        latestTranscript = ""
        isReady = false

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw STTProviderError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let trimmedProject = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty {
            request.setValue(trimmedProject, forHTTPHeaderField: "OpenAI-Project")
        }

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        webSocket = task
        task.resume()
        listenForMessages()

        // Brief window for the socket to come up, then configure.
        try await Task.sleep(for: .milliseconds(120))
        try await sendJSON([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": [
                            "model": "gpt-realtime-whisper",
                            "language": "en",
                            // Favor medical accuracy slightly over the absolute fastest captions.
                            "delay": "high"
                        ]
                    ] as [String: Any]
                ]
            ]
        ])
        isReady = true
    }

    var isConnected: Bool { isReady && webSocket != nil }

    func appendPCM24k(_ pcm: Data) {
        guard isConnected, !pcm.isEmpty else { return }
        let b64 = pcm.base64EncodedString()
        Task {
            try? await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": b64
            ])
        }
    }

    /// Endpoint the current utterance so the server emits a completed transcript.
    func commit() async {
        guard isConnected else { return }
        try? await sendJSON(["type": "input_audio_buffer.commit"])
        // Allow completed event to arrive.
        try? await Task.sleep(for: .milliseconds(350))
    }

    func close() {
        isReady = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8)
        else { return }
        try await webSocket.send(.string(string))
    }

    private func listenForMessages() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.isReady = false
                case .success(let message):
                    self.handle(message: message)
                    self.listenForMessages()
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text):
            data = text.data(using: .utf8)
        case .data(let d):
            data = d
        @unknown default:
            data = nil
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else { return }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            let delta = (json["delta"] as? String) ?? ""
            guard !delta.isEmpty else { return }
            accumulated += delta
            latestTranscript = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            onSpeechActivity?()
            onPartial?(latestTranscript)

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                latestTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                accumulated = latestTranscript
                onSpeechActivity?()
                onPartial?(latestTranscript)
            }

        case "input_audio_buffer.speech_started":
            onSpeechActivity?()

        default:
            break
        }
    }
}
