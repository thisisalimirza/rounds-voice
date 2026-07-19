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
    }

    static func map(collection: AnkiCollectionReader.Collection) -> MappingResult {
        var imported: [ImportedNote] = []
        var skippedIO = 0
        var skippedEmpty = 0
        var skippedUnsupported = 0
        var typeCounts: [String: Int] = [:]

        for raw in collection.notes {
            guard let noteType = collection.noteTypes[raw.modelID] else {
                // Unknown model — still try ordinal Text/Front if the note has content.
                if let recovered = recoverOrphanNote(raw) {
                    imported.append(recovered)
                    typeCounts["Unknown", default: 0] += 1
                } else {
                    skippedUnsupported += 1
                }
                continue
            }

            typeCounts[noteType.name, default: 0] += 1

            if isImageOcclusion(noteType: noteType) {
                skippedIO += 1
                continue
            }

            let fieldMap = dictionary(fields: raw.fields, names: noteType.fieldNames)
            let kind = classify(noteType: noteType, fields: fieldMap, rawFields: raw.fields)
            let oneByOne = isOneByOneEnabled(
                fieldMap["One by one"] ?? fieldMap["One by One"] ?? ""
            )

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
                guard !cleanedText.isEmpty else {
                    skippedEmpty += 1
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
        fields: [String: String],
        rawFields: [String]
    ) -> Kind {
        let name = noteType.name.lowercased()

        // AnKing family + standard cloze
        if noteType.type == 1
            || name.contains("anking")
            || name == "cloze"
            || name.contains("cloze")
        {
            let text = primaryClozeText(fields: fields, rawFields: rawFields)
            let extra = firstValue(in: fields, keys: [
                "Extra", "Back Extra", "Back", "Answer", "Personal Notes", "Field1"
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
        if let front = optionalValue(in: fields, keys: ["Front", "Question", "Text", "Field0"]),
           let back = optionalValue(in: fields, keys: ["Back", "Answer", "Extra", "Field1"])
        {
            return .basic(front: front, back: back)
        }

        // Fallback: first two non-empty raw fields
        let nonempty = rawFields
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if nonempty.count >= 2 {
            return .basic(front: nonempty[0], back: nonempty[1])
        }
        if let only = nonempty.first {
            return .basic(front: only, back: "")
        }
        return .skipUnsupported
    }

    /// Resolve the speakable cloze body even when field metadata is missing/misaligned.
    private static func primaryClozeText(fields: [String: String], rawFields: [String]) -> String {
        let named = firstValue(in: fields, keys: [
            "Text", "Front", "Question", "Cloze", "Content", "Field0"
        ])
        if !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return named
        }

        // Prefer the first raw field that looks like real card content (often has {{c1::}}).
        if let clozeField = rawFields.first(where: {
            ClozeParser.containsCloze($0)
                || AnkiHTMLCleaner.plainText(from: $0).count > 8
        }) {
            return clozeField
        }
        return rawFields.first ?? ""
    }

    private static func recoverOrphanNote(_ raw: AnkiCollectionReader.RawNote) -> ImportedNote? {
        guard let body = raw.fields.first(where: {
            !AnkiHTMLCleaner.plainText(from: $0).isEmpty
        }) else { return nil }

        let cleaned = AnkiHTMLCleaner.preserveClozePlainText(from: body)
        guard !cleaned.isEmpty else { return nil }
        let extra = raw.fields.dropFirst().first.map { AnkiHTMLCleaner.plainText(from: $0) } ?? ""

        if ClozeParser.containsCloze(cleaned) {
            return ImportedNote(
                front: cleaned,
                back: extra,
                tags: raw.tags,
                cardType: .cloze,
                ankiNoteId: String(raw.id)
            )
        }
        return ImportedNote(
            front: AnkiHTMLCleaner.plainText(from: body),
            back: extra,
            tags: raw.tags,
            cardType: .basic,
            ankiNoteId: String(raw.id)
        )
    }

    static func isImageOcclusion(noteType: AnkiCollectionReader.NoteType) -> Bool {
        let name = noteType.name.lowercased()
        if name.contains("image occlusion")
            || name.contains("io-one")
            || name.contains("io one")
            || name.hasPrefix("io-")
            || name == "io"
            || name.contains("imageocclusion")
            || name.contains("io-one by one")
        {
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
        let resolvedNames: [String]
        if names.isEmpty {
            // Same ordinal fallback as the collection reader.
            resolvedNames = [
                "Text", "Extra", "Personal Notes", "Missed Questions",
                "Lecture Notes", "Boards and Beyond", "First Aid",
                "Sketchy", "Pixorize", "Physeo", "One by one"
            ]
        } else {
            resolvedNames = names
        }

        for (index, name) in resolvedNames.enumerated() {
            map[name] = index < fields.count ? fields[index] : ""
        }
        if fields.count > resolvedNames.count {
            for i in resolvedNames.count..<fields.count {
                map["Field\(i)"] = fields[i]
            }
        }
        // Always expose ordinals so classify can recover.
        for (index, value) in fields.enumerated() {
            map["Field\(index)"] = value
        }
        return map
    }

    private static func firstValue(in fields: [String: String], keys: [String]) -> String {
        for key in keys {
            if let value = fields[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let pair = fields.first(where: { $0.key.lowercased() == key.lowercased() }),
               !pair.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return pair.value
            }
        }
        // Fuzzy: "Text (AnKing)" / "Cloze Text" etc.
        for key in keys {
            let needle = key.lowercased()
            if let pair = fields.first(where: {
                $0.key.lowercased().contains(needle)
                    && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
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
