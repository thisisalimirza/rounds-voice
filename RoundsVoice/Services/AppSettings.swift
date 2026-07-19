import Foundation
import Security

/// Persisted preferences for AI grading and natural TTS.
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    enum GraderEngine: String, CaseIterable, Identifiable, Sendable {
        case heuristic
        case openAI

        var id: String { rawValue }

        var title: String {
            switch self {
            case .heuristic: return "Offline heuristic"
            case .openAI: return "AI professor (OpenAI)"
            }
        }

        var subtitle: String {
            switch self {
            case .heuristic: return "Keyword overlap · works without a key"
            case .openAI: return "Synonyms & mechanisms · needs API key"
            }
        }
    }

    var graderEngine: GraderEngine {
        didSet { UserDefaults.standard.set(graderEngine.rawValue, forKey: Keys.graderEngine) }
    }

    var openAIModel: String {
        didSet { UserDefaults.standard.set(openAIModel, forKey: Keys.openAIModel) }
    }

    /// Optional OpenAI project id (`proj_…`) sent as `OpenAI-Project` header.
    var openAIProjectID: String {
        didSet { UserDefaults.standard.set(openAIProjectID, forKey: Keys.openAIProjectID) }
    }

    var openAIAPIKey: String {
        didSet { KeychainStore.set(openAIAPIKey, for: .openAIAPIKey) }
    }

    var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: Keys.ttsEngine) }
    }

    var ttsVoice: OpenAITTSVoice {
        didSet { UserDefaults.standard.set(ttsVoice.rawValue, forKey: Keys.ttsVoice) }
    }

    var ttsModel: String {
        didSet { UserDefaults.standard.set(ttsModel, forKey: Keys.ttsModel) }
    }

    /// OpenAI TTS playback rate (0.25…4.0). Default slightly brisk for walking reviews.
    var ttsSpeed: Double {
        didSet { UserDefaults.standard.set(ttsSpeed, forKey: Keys.ttsSpeed) }
    }

    /// Prefer OpenAI speech-to-text when a key is present (Apple is offline fallback).
    var useOpenAISTT: Bool {
        didSet { UserDefaults.standard.set(useOpenAISTT, forKey: Keys.useOpenAISTT) }
    }

    var sttModel: String {
        didSet { UserDefaults.standard.set(sttModel, forKey: Keys.sttModel) }
    }

    var hasOpenAIKey: Bool {
        !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Natural OpenAI TTS when selected and a key is present.
    var shouldUseOpenAITTS: Bool {
        ttsEngine == .openAI && hasOpenAIKey
    }

    /// Cloud STT for medical vocabulary when enabled and keyed.
    var shouldUseOpenAISTT: Bool {
        useOpenAISTT && hasOpenAIKey
    }

    /// Effective grader: AI when configured, otherwise heuristic.
    var makeGrader: any AIGraderService {
        switch graderEngine {
        case .openAI where hasOpenAIKey:
            return LLMAnswerGrader(
                provider: OpenAIProvider(
                    apiKey: openAIAPIKey,
                    model: openAIModel,
                    projectID: openAIProjectID
                )
            )
        case .openAI:
            return HeuristicAnswerGrader()
        case .heuristic:
            return HeuristicAnswerGrader()
        }
    }

    var makeOpenAITTSProvider: OpenAITTSProvider? {
        guard shouldUseOpenAITTS else { return nil }
        return OpenAITTSProvider(
            apiKey: openAIAPIKey,
            model: ttsModel,
            voice: ttsVoice,
            projectID: openAIProjectID,
            speed: ttsSpeed
        )
    }

    var makeOpenAISTTProvider: OpenAITranscriptionProvider? {
        guard shouldUseOpenAISTT else { return nil }
        return OpenAITranscriptionProvider(
            apiKey: openAIAPIKey,
            model: sttModel,
            projectID: openAIProjectID
        )
    }

    private init() {
        graderEngine = GraderEngine(rawValue: UserDefaults.standard.string(forKey: Keys.graderEngine) ?? "")
            ?? .heuristic
        openAIModel = UserDefaults.standard.string(forKey: Keys.openAIModel) ?? "gpt-4o-mini"
        openAIProjectID = UserDefaults.standard.string(forKey: Keys.openAIProjectID) ?? ""
        let storedKey = KeychainStore.get(.openAIAPIKey) ?? ""
        openAIAPIKey = storedKey
        let keyPresent = !storedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ttsEngine = TTSEngine(rawValue: UserDefaults.standard.string(forKey: Keys.ttsEngine) ?? "")
            ?? (keyPresent ? .openAI : .apple)
        ttsVoice = OpenAITTSVoice(rawValue: UserDefaults.standard.string(forKey: Keys.ttsVoice) ?? "")
            ?? .marin
        ttsModel = UserDefaults.standard.string(forKey: Keys.ttsModel) ?? "gpt-4o-mini-tts"
        let storedSpeed = UserDefaults.standard.object(forKey: Keys.ttsSpeed) as? Double
        ttsSpeed = storedSpeed ?? 1.15
        if UserDefaults.standard.object(forKey: Keys.useOpenAISTT) == nil {
            useOpenAISTT = keyPresent
        } else {
            useOpenAISTT = UserDefaults.standard.bool(forKey: Keys.useOpenAISTT)
        }
        sttModel = UserDefaults.standard.string(forKey: Keys.sttModel) ?? "gpt-4o-transcribe"

        if keyPresent, graderEngine == .heuristic {
            graderEngine = .openAI
        }
    }

    private enum Keys {
        static let graderEngine = "rv.graderEngine"
        static let openAIModel = "rv.openAIModel"
        static let openAIProjectID = "rv.openAIProjectID"
        static let ttsEngine = "rv.ttsEngine"
        static let ttsVoice = "rv.ttsVoice"
        static let ttsModel = "rv.ttsModel"
        static let ttsSpeed = "rv.ttsSpeed"
        static let useOpenAISTT = "rv.useOpenAISTT"
        static let sttModel = "rv.sttModel"
    }
}

enum KeychainStore {
    enum Account: String {
        case openAIAPIKey = "com.roundsvoice.openai"
    }

    static func set(_ value: String, for account: Account) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
