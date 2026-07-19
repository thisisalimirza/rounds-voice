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
        You grade hands-free Anki / AnKing answers for a medical student walking.

        The card has a fixed expected answer (cloze blank or back). Grade against THAT, not a vague topic.

        Speech-to-text is noisy: missing first words, wrong drug spelling, "activates" vs "activist", \
        "B6" vs "vitamin B6", abbreviations. Accept clear semantic matches and standard synonyms.

        Mark correct when the student hit the teaching point, even if wording differs.
        Mark incorrect only when the critical fact is wrong or missing.

        Feedback rules (spoken aloud — keep to one short sentence):
        - If correct: "Correct." or a brief affirmation. Do NOT restate the whole answer.
        - If incorrect or incomplete: MUST end with the exact expected answer, e.g. \
          "Not quite. The answer is pyridoxine (vitamin B6)." \
          Never say only "incorrect" or "incomplete mechanism" without stating the answer.

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
        // Fast path: obvious match / STT-near match — don't wait on the network.
        if let quick = AnswerMatching.quickGrade(expected: expectedAnswer, spoken: userAnswer) {
            return quick
        }

        let userPrompt = """
        Question (spoken): \(question)
        Expected answer (card back / cloze): \(expectedAnswer)
        Student said (speech-to-text): \(userAnswer)
        """

        do {
            let raw = try await provider.complete(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
            let parsed = try Self.parseGrade(from: raw)
            return AnswerMatching.ensureAnswerRevealed(parsed, expected: expectedAnswer)
        } catch {
            let fallbackGrade = try await fallback.gradeAnswer(
                question: question,
                expectedAnswer: expectedAnswer,
                userAnswer: userAnswer
            )
            return AnswerMatching.ensureAnswerRevealed(fallbackGrade, expected: expectedAnswer)
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
        if let quick = AnswerMatching.quickGrade(expected: expectedAnswer, spoken: userAnswer) {
            return quick
        }

        let expectedTokens = AnswerMatching.tokenize(expectedAnswer)
        let userTokens = AnswerMatching.tokenize(userAnswer)

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
        // Also credit if the full expected phrase (normalized) appears in what they said.
        let phraseHit = AnswerMatching.normalized(userAnswer)
            .contains(AnswerMatching.normalized(expectedAnswer))
            && AnswerMatching.normalized(expectedAnswer).count >= 3

        let isCorrect = recall >= 0.45 || phraseHit
        let feedback: String
        if isCorrect {
            feedback = "Correct."
        } else if recall >= 0.25 {
            feedback = "Partially correct. The answer is \(expectedAnswer)."
        } else {
            feedback = "Incorrect. The answer is \(expectedAnswer)."
        }

        return GradeResult(
            isCorrect: isCorrect,
            confidence: min(0.85, recall + 0.15),
            feedback: feedback,
            score: Int((recall * 100).rounded())
        )
    }
}

/// Shared matching helpers for noisy medical speech-to-text.
enum AnswerMatching {
    static func quickGrade(expected: String, spoken: String) -> GradeResult? {
        let e = normalized(expected)
        let s = normalized(spoken)
        guard !e.isEmpty, !s.isEmpty else { return nil }

        if e == s || s.contains(e) || e.contains(s) {
            return GradeResult(isCorrect: true, confidence: 0.92, feedback: "Correct.", score: 95)
        }

        // Token containment for short cloze answers (e.g. expected "ampk", said "activates ampk").
        let expectedTokens = tokenize(expected)
        let spokenTokens = tokenize(spoken)
        if !expectedTokens.isEmpty, expectedTokens.isSubset(of: spokenTokens) {
            return GradeResult(isCorrect: true, confidence: 0.88, feedback: "Correct.", score: 90)
        }

        return nil
    }

    static func ensureAnswerRevealed(_ grade: GradeResult, expected: String) -> GradeResult {
        let expectedClean = expected
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !grade.isCorrect, !expectedClean.isEmpty else { return grade }

        let feedback = grade.feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyRevealed = feedback.localizedCaseInsensitiveContains(expectedClean)
            || normalized(feedback).contains(normalized(expectedClean))
        if alreadyRevealed { return grade }

        let prefix = feedback.isEmpty || feedback.lowercased() == "incorrect."
            ? "Incorrect."
            : feedback.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + "."
        return GradeResult(
            isCorrect: false,
            confidence: grade.confidence,
            feedback: "\(prefix) The answer is \(expectedClean).",
            score: grade.score
        )
    }

    static func normalized(_ text: String) -> String {
        var t = text.lowercased()
        let replacements: [(String, String)] = [
            ("vitamin ", ""),
            ("vit ", ""),
            ("approx", ""),
            ("approximately", ""),
            ("the ", ""),
            ("a ", ""),
            ("an ", "")
        ]
        for (a, b) in replacements {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func tokenize(_ text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "a", "an", "the", "of", "and", "or", "to", "in", "on", "for",
            "with", "by", "is", "are", "it", "that", "this", "through",
            "um", "uh", "like", "just"
        ]

        return Set(
            normalized(text)
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty && !stopwords.contains($0) && $0.count > 1 }
        )
    }
}
