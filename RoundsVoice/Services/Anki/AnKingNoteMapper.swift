import Foundation

/// Maps Anki notes — especially AnKing note types — into voice-suitable cards.
///
/// Supported for voice review:
/// - AnKing / AnKingOverhaul / AnKing* cloze notes (`Text` + `Extra`)
/// - Standard Anki Cloze (`Text` + `Extra`)
/// - Basic / Basic (and reversed card) (`Front`/`Back`)
///
/// Skipped (visual-only / not speakable):
/// - Image Occlusion / IO-one by one / IO Enhanced
/// - Notes whose primary content is only images
enum AnKingNoteMapper {
    struct MappingResult: Sendable, Equatable {
        var notes: [ImportedNote]
        var skippedImageOcclusion: Int
        var skippedEmpty: Int
        var skippedUnsupportedType: Int
        var noteTypeCounts: [String: Int]

        var skippedTotal: Int {
            skippedImageOcclusion + skippedEmpty + skippedUnsupportedType
        }
    }

    static func map(collection: AnkiCollectionReader.Collection) -> MappingResult {
        var imported: [ImportedNote] = []
        var skippedIO = 0
        var skippedEmpty = 0
        var skippedUnsupported = 0
        var typeCounts: [String: Int] = [:]

        for raw in collection.notes {
            guard let noteType = collection.noteTypes[raw.modelID] else {
                skippedUnsupported += 1
                continue
            }

            typeCounts[noteType.name, default: 0] += 1

            if isImageOcclusion(noteType: noteType) {
                skippedIO += 1
                continue
            }

            let fieldMap = dictionary(fields: raw.fields, names: noteType.fieldNames)
            let kind = classify(noteType: noteType, fields: fieldMap)
            let oneByOne = isOneByOneEnabled(fieldMap["One by one"] ?? "")

            switch kind {
            case .skipUnsupported:
                skippedUnsupported += 1
            case .skipEmpty:
                skippedEmpty += 1
            case .cloze(let text, let extra):
                let cleanedText = AnkiHTMLCleaner.preserveClozePlainText(from: text)
                guard ClozeParser.containsCloze(cleanedText) || noteType.type == 1 else {
                    let front = AnkiHTMLCleaner.plainText(from: text)
                    let back = AnkiHTMLCleaner.plainText(from: extra)
                    if front.isEmpty {
                        skippedEmpty += 1
                    } else {
                        imported.append(
                            ImportedNote(
                                front: front,
                                back: back.isEmpty ? front : back,
                                tags: enrichedTags(raw.tags, noteType: noteType.name),
                                cardType: .basic,
                                ankiNoteId: String(raw.id)
                            )
                        )
                    }
                    continue
                }
                imported.append(
                    ImportedNote(
                        front: cleanedText,
                        back: AnkiHTMLCleaner.plainText(from: extra),
                        tags: enrichedTags(raw.tags, noteType: noteType.name),
                        cardType: .cloze,
                        ankiNoteId: String(raw.id),
                        oneByOne: oneByOne
                    )
                )
            case .basic(let front, let back):
                let q = AnkiHTMLCleaner.plainText(from: front)
                let a = AnkiHTMLCleaner.plainText(from: back)
                if q.isEmpty {
                    skippedEmpty += 1
                } else {
                    imported.append(
                        ImportedNote(
                            front: q,
                            back: a,
                            tags: enrichedTags(raw.tags, noteType: noteType.name),
                            cardType: .basic,
                            ankiNoteId: String(raw.id)
                        )
                    )
                }
            }
        }

        return MappingResult(
            notes: imported,
            skippedImageOcclusion: skippedIO,
            skippedEmpty: skippedEmpty,
            skippedUnsupportedType: skippedUnsupported,
            noteTypeCounts: typeCounts
        )
    }

    // MARK: - Classification

    private enum Kind {
        case cloze(text: String, extra: String)
        case basic(front: String, back: String)
        case skipEmpty
        case skipUnsupported
    }

    private static func classify(
        noteType: AnkiCollectionReader.NoteType,
        fields: [String: String]
    ) -> Kind {
        let name = noteType.name.lowercased()

        // AnKing family + standard cloze
        if noteType.type == 1
            || name.contains("anking")
            || name == "cloze"
            || name.contains("cloze")
        {
            let text = firstValue(in: fields, keys: ["Text", "Front", "Question"])
            let extra = firstValue(in: fields, keys: [
                "Extra", "Back Extra", "Back", "Answer", "Personal Notes"
            ])
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .skipEmpty
            }
            if isImageOnly(text) && !ClozeParser.containsCloze(text) {
                return .skipEmpty
            }
            return .cloze(text: text, extra: extra)
        }

        // Basic / reverse / custom front-back
        if let front = optionalValue(in: fields, keys: ["Front", "Question"]),
           let back = optionalValue(in: fields, keys: ["Back", "Answer"])
        {
            return .basic(front: front, back: back)
        }

        // Fallback: first two fields
        let values = noteType.fieldNames.compactMap { fields[$0] }
        if values.count >= 2 {
            return .basic(front: values[0], back: values[1])
        }
        if let only = values.first, !only.isEmpty {
            return .basic(front: only, back: "")
        }
        return .skipUnsupported
    }

    static func isImageOcclusion(noteType: AnkiCollectionReader.NoteType) -> Bool {
        let name = noteType.name.lowercased()
        if name.contains("image occlusion")
            || name.contains("io-one")
            || name.contains("io one")
            || name.hasPrefix("io-")
            || name == "io"
            || name.contains("imageocclusion")
        {
            return true
        }
        // AnKing IO note types are named like "IO-one by one (AnKing Step Deck / …)"
        if name.hasPrefix("io-") || name.contains("io-one by one") {
            return true
        }
        let fields = Set(noteType.fieldNames.map { $0.lowercased() })
        if fields.contains("image") && (fields.contains("i0") || fields.contains("occlusion")) {
            return true
        }
        return false
    }

    /// AnKing "One by one" field — any non-empty value (commonly `y` / `yes`).
    static func isOneByOneEnabled(_ raw: String) -> Bool {
        let plain = AnkiHTMLCleaner.plainText(from: raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !plain.isEmpty, plain != "," else { return false }
        return true
    }

    private static func dictionary(fields: [String], names: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for (index, name) in names.enumerated() {
            map[name] = index < fields.count ? fields[index] : ""
        }
        // Also expose by ordinal if names shorter than fields
        if fields.count > names.count {
            for i in names.count..<fields.count {
                map["Field\(i)"] = fields[i]
            }
        }
        return map
    }

    private static func firstValue(in fields: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = fields[key], !value.isEmpty { return value }
            // Case-insensitive fallback
            if let pair = fields.first(where: { $0.key.lowercased() == key.lowercased() }),
               !pair.value.isEmpty
            {
                return pair.value
            }
        }
        return ""
    }

    private static func optionalValue(in fields: [String: String], keys: [String]) -> String? {
        let value = firstValue(in: fields, keys: keys)
        return value.isEmpty ? nil : value
    }

    private static func enrichedTags(_ tags: [String], noteType: String) -> [String] {
        var result = tags
        if !result.contains(where: { $0.caseInsensitiveCompare(noteType) == .orderedSame }) {
            result.append("note:\(noteType)")
        }
        return result
    }

    private static func isImageOnly(_ html: String) -> Bool {
        let withoutImages = html.replacingOccurrences(
            of: #"<img\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return AnkiHTMLCleaner.plainText(from: withoutImages).isEmpty
            && html.localizedCaseInsensitiveContains("<img")
    }
}

extension AnkiHTMLCleaner {
    /// Strips HTML while preserving Anki cloze `{{cN::...}}` markers.
    static func preserveClozePlainText(from html: String) -> String {
        // Temporarily protect cloze tokens from tag stripping edge cases
        var text = html
        text = text.replacingOccurrences(of: "<br>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br/>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<br />", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<div>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "</div>", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(
            of: #"\[sound:[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
