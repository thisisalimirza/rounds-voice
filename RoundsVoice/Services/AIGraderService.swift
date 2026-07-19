import Foundation

/// Provider-agnostic LLM client used by grading and (later) explanation.
protocol LLMProvider: Sendable {
    var displayName: String { get }
    func complete(systemPrompt: String, userPrompt: String) async throws -> String
}

enum LLMProviderError: LocalizedError, Sendable {
    case missingAPIKey
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Add one in Settings."
        case .invalidResponse:
            return "The language model returned an invalid response."
        case .httpError(let statusCode, let body):
            return "LLM request failed (\(statusCode)): \(body.prefix(200))"
        case .decodingFailed:
            return "Couldn't decode the language model response."
        }
    }
}

/// OpenAI Chat Completions provider. Swappable via `LLMProvider`.
struct OpenAIProvider: LLMProvider {
    var displayName: String { "OpenAI" }
    var apiKey: String
    var model: String
    var projectID: String
    var baseURL: URL

    init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        projectID: String = "",
        baseURL: URL = URL(string: "https://api.openai.com/v1")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.projectID = projectID
        self.baseURL = baseURL
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey
        }

        let endpoint = baseURL.appending(path: "chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedProject = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProject.isEmpty {
            request.setValue(trimmedProject, forHTTPHeaderField: "OpenAI-Project")
        }
        request.timeoutInterval = 30

        let body = ChatCompletionsRequest(
            model: model,
            temperature: 0.1,
            responseFormat: .init(type: "json_object"),
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userPrompt)
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw LLMProviderError.httpError(statusCode: http.statusCode, body: bodyText)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionsResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw LLMProviderError.decodingFailed
        }
        return content
    }
}

// MARK: - OpenAI DTOs

private struct ChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    struct ResponseFormat: Encodable {
        var type: String
    }

    var model: String
    var temperature: Double
    var responseFormat: ResponseFormat
    var messages: [Message]

    enum CodingKeys: String, CodingKey {
        case model, temperature, messages
        case responseFormat = "response_format"
    }
}

private struct ChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }
        var message: Message
    }
    var choices: [Choice]
}

/// Grades spoken answers like a medical school professor.
protocol AIGraderService: Sendable {
    func gradeAnswer(
        question: String,
        expectedAnswer: String,
        userAnswer: String
    ) async throws -> GradeResult
}

/// Production grader backed by an `LLMProvider`.
struct LLMAnswerGrader: AIGraderService {
    private let provider: any LLMProvider
    private let fallback: HeuristicAnswerGrader

    init(provider: any LLMProvider, fallback: HeuristicAnswerGrader = HeuristicAnswerGrader()) {
        self.provider = provider
        self.fallback = fallback
    }

    private var systemPrompt: String {
        """
        You are a medical school professor grading a student's spoken Anki answer during a hands-free review.

        Accept:
        - Synonyms and equivalent phrasings
        - Correct mechanisms stated in different order
        - Standard medical abbreviations (e.g., HTN, MI, AMPK, COX)
        - Partial articles/filler from speech-to-text noise

        Reject:
        - Vague answers ("it helps diabetes", "it's an antibiotic")
        - Incorrect mechanisms or wrong drug class
        - Answers that miss the critical teaching point

        Feedback must be ONE short sentence suitable for text-to-speech.
        If correct, prefer "Correct." or a brief affirmation.
        If incorrect, briefly name the key expected idea without lecturing.

        Respond with ONLY JSON:
        {"isCorrect":true,"confidence":0.0,"feedback":"...","score":0}
        confidence is 0-1. score is 0-100.
        """
    }

    func gradeAnswer(
        question: String,
        expectedAnswer: String,
        userAnswer: String
    ) async throws -> GradeResult {
        let userPrompt = """
        Question: \(question)
        Expected answer: \(expectedAnswer)
        Student answer: \(userAnswer)
        """

        do {
            let raw = try await provider.complete(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            return try Self.parseGrade(from: raw)
        } catch {
            // Keep the walking session alive if the network/API fails.
            return try await fallback.gradeAnswer(
                question: question,
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer
            )
        }
    }

    static func parseGrade(from raw: String) throws -> GradeResult {
        let trimmed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = trimmed.data(using: .utf8) else {
            throw LLMProviderError.decodingFailed
        }

        struct Payload: Decodable {
            var isCorrect: Bool
            var confidence: Double
            var feedback: String
            var score: Int?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return GradeResult(
            isCorrect: payload.isCorrect,
            confidence: payload.confidence,
            feedback: payload.feedback,
            score: payload.score
        )
    }
}

/// Offline grader used when no API key is configured.
struct HeuristicAnswerGrader: AIGraderService {
    func gradeAnswer(
        question: String,
        expectedAnswer: String,
        userAnswer: String
    ) async throws -> GradeResult {
        _ = question
        let expectedTokens = tokenize(expectedAnswer)
        let userTokens = tokenize(userAnswer)

        guard !expectedTokens.isEmpty else {
            return GradeResult(
                isCorrect: !userTokens.isEmpty,
                confidence: 0.4,
                feedback: userTokens.isEmpty ? "No answer detected." : "Accepted.",
                score: userTokens.isEmpty ? 0 : 60
            )
        }

        let overlap = expectedTokens.intersection(userTokens)
        let recall = Double(overlap.count) / Double(expectedTokens.count)

        let isCorrect = recall >= 0.55
        let feedback: String
        if isCorrect {
            feedback = "Correct."
        } else if recall >= 0.3 {
            feedback = "Partially correct. Expected: \(expectedAnswer)"
        } else {
            feedback = "Incorrect. Expected: \(expectedAnswer)"
        }

        return GradeResult(
            isCorrect: isCorrect,
            confidence: min(0.85, recall + 0.15),
            feedback: feedback,
            score: Int((recall * 100).rounded())
        )
    }

    private func tokenize(_ text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "a", "an", "the", "of", "and", "or", "to", "in", "on", "for",
            "with", "by", "is", "are", "it", "that", "this", "through"
        ]

        let cleaned = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) && $0.count > 1 }

        return Set(cleaned)
    }
}
