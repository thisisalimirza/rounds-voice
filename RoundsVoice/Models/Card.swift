import Foundation
import SwiftData

/// A flashcard suitable for voice-first review.
@Model
final class Card {
    @Attribute(.unique) var id: UUID
    var front: String
    var back: String
    var tags: [String]
    var deckName: String
    var dueDate: Date
    var interval: Double
    var easeFactor: Double
    var reviewCount: Int
    var lastReviewed: Date?
    var imageAttachments: [String]
    var cardType: CardType
    var clozeNumber: Int?
    /// When set, this card is one step in an AnKing one-by-one / sequential cloze chain.
    var clozeOrdinal: Int?
    var ankiNoteId: String?
    /// Shared note identity for sibling bury (`ankiNoteId` with `#ordinal` stripped).
    var siblingKey: String = ""
    /// Anki-style suspend — excluded from due counts and review sessions.
    var isSuspended: Bool = false
    /// Anki-style bury — hidden from due queues until this date (usually tomorrow).
    var buriedUntil: Date?
    /// FSRS stability (days).
    var stability: Double = 0
    /// FSRS difficulty (1…10).
    var difficulty: Double = 0
    /// Successful + failed review reps for FSRS.
    var reps: Int = 0
    /// Times the card lapsed (Again from review).
    var lapses: Int = 0
    /// `FSRSState` raw value.
    var fsrsState: Int = 0
    /// Lowercased plain text for fast SwiftData search predicates (no cloze parsing).
    var searchBlob: String = ""
    /// Exact tag tokens delimited for predicate-friendly matching (`␟tag␟`).
    var tagsBlob: String = ""
    /// Persisted TTS prompt (baseline or LLM-polished). Empty → fall back to computed speech.
    var voicePrompt: String = ""
    /// Persisted spoken answer target for STT / grading.
    var voiceAnswer: String = ""
    /// `VoiceScriptSource.rawValue` — `baseline` or `llm`.
    var voiceScriptSource: String = ""
    /// Hash of front/back/cloze identity; mismatch means script is stale.
    var voiceScriptHash: String = ""
    var createdAt: Date
    var updatedAt: Date

    var deck: Deck?

    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        tags: [String] = [],
        deckName: String,
        dueDate: Date = .now,
        interval: Double = 0,
        easeFactor: Double = 2.5,
        reviewCount: Int = 0,
        lastReviewed: Date? = nil,
        imageAttachments: [String] = [],
        cardType: CardType = .basic,
        clozeNumber: Int? = nil,
        clozeOrdinal: Int? = nil,
        ankiNoteId: String? = nil,
        isSuspended: Bool = false,
        buriedUntil: Date? = nil,
        stability: Double = 0,
        difficulty: Double = 0,
        reps: Int = 0,
        lapses: Int = 0,
        fsrsState: Int = 0,
        deck: Deck? = nil
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.tags = tags
        self.deckName = deckName
        self.dueDate = dueDate
        self.interval = interval
        self.easeFactor = easeFactor
        self.reviewCount = reviewCount
        self.lastReviewed = lastReviewed
        self.imageAttachments = imageAttachments
        self.cardType = cardType
        self.clozeNumber = clozeNumber
        self.clozeOrdinal = clozeOrdinal
        self.ankiNoteId = ankiNoteId
        self.siblingKey = Self.makeSiblingKey(from: ankiNoteId)
        self.isSuspended = isSuspended
        self.buriedUntil = buriedUntil
        self.stability = stability
        self.difficulty = difficulty
        self.reps = reps
        self.lapses = lapses
        self.fsrsState = fsrsState
        self.deck = deck
        self.createdAt = .now
        self.updatedAt = .now
        self.searchBlob = Self.makeSearchBlob(front: front, back: back, tags: tags)
        self.tagsBlob = Self.makeTagsBlob(tags)
        VoiceScriptBaseline.apply(to: self)
    }

    func refreshSearchBlob() {
        searchBlob = Self.makeSearchBlob(front: front, back: back, tags: tags)
        tagsBlob = Self.makeTagsBlob(tags)
        siblingKey = Self.makeSiblingKey(from: ankiNoteId)
    }

    /// Rebuild baseline voice script when missing or content changed.
    func ensureVoiceScriptReady() {
        VoiceScriptBaseline.ensureFresh(self)
    }

    static func makeSiblingKey(from ankiNoteId: String?) -> String {
        guard let raw = ankiNoteId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return "" }
        if let hash = raw.firstIndex(of: "#") {
            return String(raw[..<hash])
        }
        return raw
    }

    static func makeSearchBlob(front: String, back: String, tags: [String]) -> String {
        let plainFront = AnkiHTMLCleaner.plainText(from: front)
        let plainBack = AnkiHTMLCleaner.plainText(from: back)
        return ([plainFront, plainBack] + tags)
            .joined(separator: " ")
            .lowercased()
    }

    /// Unit separator keeps exact tag matches from colliding as substrings.
    static let tagDelimiter = "\u{001F}"

    static func makeTagsBlob(_ tags: [String]) -> String {
        let parts = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }
        return tagDelimiter + parts.joined(separator: tagDelimiter) + tagDelimiter
    }

    static func tagsBlobToken(_ tag: String) -> String {
        tagDelimiter + tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + tagDelimiter
    }

    /// Active cloze slot for voice — prefers stored ordinal; falls back so old imports
    /// with multiple blanks still grade exactly one answer.
    private var resolvedClozeOrdinal: Int? {
        if let clozeOrdinal { return clozeOrdinal }
        let items = ClozeParser.deletions(in: front)
        guard items.count > 1 else { return items.isEmpty ? nil : 0 }
        if let n = clozeNumber, let match = items.first(where: { $0.number == n }) {
            return match.ordinal
        }
        return 0
    }

    /// Text the TTS engine should read (exactly one “blank” per card).
    var spokenQuestion: String {
        switch cardType {
        case .basic:
            return ClozeParser.sanitizeSpoken(AnkiHTMLCleaner.plainText(from: front))
        case .cloze:
            if let ordinal = resolvedClozeOrdinal, ClozeParser.deletions(in: front).count > 1 {
                return ClozeParser.spokenQuestionSequential(from: front, activeOrdinal: ordinal)
            }
            return ClozeParser.spokenQuestion(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
        }
    }

    /// On-screen prompt — only the active blank is `[...]`; later blanks are `⋯`.
    var displayQuestion: String {
        switch cardType {
        case .basic:
            return AnkiHTMLCleaner.plainText(from: front)
        case .cloze:
            if let ordinal = resolvedClozeOrdinal, ClozeParser.deletions(in: front).count > 1 {
                return ClozeParser.displayQuestionSequential(from: front, activeOrdinal: ordinal)
            }
            return ClozeParser.displayQuestion(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
        }
    }

    var spokenAnswer: String {
        switch cardType {
        case .basic:
            return AnkiHTMLCleaner.plainText(from: back)
        case .cloze:
            if let ordinal = resolvedClozeOrdinal, ClozeParser.deletions(in: front).count > 1 {
                return ClozeParser.spokenAnswerSequential(from: front, activeOrdinal: ordinal)
            }
            let fromCloze = ClozeParser.spokenAnswer(
                from: front,
                clozeNumber: clozeNumber ?? 1
            )
            if !fromCloze.isEmpty { return fromCloze }
            return AnkiHTMLCleaner.plainText(from: back)
        }
    }

    /// Prefer persisted voice script; fall back to computed spoken fields.
    var effectiveVoicePrompt: String {
        let trimmed = voicePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spokenQuestion : trimmed
    }

    var effectiveVoiceAnswer: String {
        let trimmed = voiceAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? spokenAnswer : trimmed
    }

    var isBuried: Bool {
        guard let buriedUntil else { return false }
        return buriedUntil > .now
    }

    var isDue: Bool {
        !isSuspended && !isBuried && dueDate <= .now
    }
}

enum CardType: String, Codable, CaseIterable, Sendable {
    case basic
    case cloze
}

enum VoiceScriptSource: String, Codable, CaseIterable, Sendable {
    case baseline
    case llm
}
