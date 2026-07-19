import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Import Abstractions

struct ImportedDeck: Sendable, Equatable {
    var name: String
    var description: String
    var source: DeckSource
    var notes: [ImportedNote]
    var importReport: ImportReport? = nil

    struct ImportReport: Sendable, Equatable {
        var totalAnkiNotes: Int
        var importedNotes: Int
        var skippedImageOcclusion: Int
        var skippedEmpty: Int
        var skippedUnsupportedType: Int
        var noteTypeCounts: [String: Int]

        var summary: String {
            var parts: [String] = ["\(importedNotes) voice-ready notes"]
            if skippedImageOcclusion > 0 {
                parts.append("\(skippedImageOcclusion) image occlusion skipped")
            }
            if skippedEmpty > 0 {
                parts.append("\(skippedEmpty) empty skipped")
            }
            if skippedUnsupportedType > 0 {
                parts.append("\(skippedUnsupportedType) unsupported skipped")
            }
            return parts.joined(separator: " · ")
        }
    }
}

struct ImportedNote: Sendable, Equatable {
    var front: String
    var back: String
    var tags: [String]
    var cardType: CardType
    var ankiNoteId: String?
    var imageAttachments: [String]
    /// AnKing "One by one" — reveal cloze blanks sequentially.
    var oneByOne: Bool

    init(
        front: String,
        back: String,
        tags: [String] = [],
        cardType: CardType = .basic,
        ankiNoteId: String? = nil,
        imageAttachments: [String] = [],
        oneByOne: Bool = false
    ) {
        self.front = front
        self.back = back
        self.tags = tags
        self.cardType = cardType
        self.ankiNoteId = ankiNoteId
        self.imageAttachments = imageAttachments
        self.oneByOne = oneByOne
    }
}

enum DeckImportError: LocalizedError, Sendable {
    case unsupportedFormat
    case unreadableFile
    case emptyDeck
    case parsingFailed(String)
    case noVoiceSuitableCards(ImportReportPlaceholder)

    struct ImportReportPlaceholder: Sendable {
        var message: String
    }

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format isn't supported. Export an .apkg from Anki."
        case .unreadableFile:
            return "Couldn't read the selected file."
        case .emptyDeck:
            return "The deck didn't contain any cards."
        case .parsingFailed(let detail):
            return "Failed to parse deck: \(detail)"
        case .noVoiceSuitableCards(let report):
            return report.message
        }
    }
}

extension UTType {
    static var ankiPackage: UTType {
        UTType(filenameExtension: "apkg") ?? .data
    }

    static var ankiColPackage: UTType {
        UTType(filenameExtension: "colpkg") ?? .data
    }
}

protocol DeckImporter: Sendable {
    var displayName: String { get }
    func importDeck(from url: URL) async throws -> ImportedDeck
}

// MARK: - Anki .apkg importer

/// Parses Anki packages with first-class AnKing note-type support.
struct AnkiDeckImporter: DeckImporter {
    var displayName: String { "Anki Package (.apkg)" }

    func importDeck(from url: URL) async throws -> ImportedDeck {
        let ext = url.pathExtension.lowercased()
        guard ext == "apkg" || ext == "colpkg" else {
            throw DeckImportError.unsupportedFormat
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundsVoiceImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Copy into our sandbox first — large AnKing packages from Files/iCloud can lose
        // security-scoped access mid-read if we unzip straight from the picker URL.
        let localPackage = tempRoot.appendingPathComponent("package.\(ext)")
        do {
            if FileManager.default.fileExists(atPath: localPackage.path) {
                try FileManager.default.removeItem(at: localPackage)
            }
            try FileManager.default.copyItem(at: url, to: localPackage)
        } catch {
            throw DeckImportError.unreadableFile
        }

        let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        do {
            try ZipArchive.extract(archiveURL: localPackage, to: extractDir)
        } catch let error as DeckImportError {
            throw error
        } catch {
            throw DeckImportError.unreadableFile
        }

        let dbURL = try prepareCollectionDatabase(in: extractDir)
        let collection = try AnkiCollectionReader.load(databaseURL: dbURL)
        let mapped = AnKingNoteMapper.map(collection: collection)

        let report = ImportedDeck.ImportReport(
            totalAnkiNotes: collection.notes.count,
            importedNotes: mapped.notes.count,
            skippedImageOcclusion: mapped.skippedImageOcclusion,
            skippedEmpty: mapped.skippedEmpty,
            skippedUnsupportedType: mapped.skippedUnsupportedType,
            noteTypeCounts: mapped.noteTypeCounts
        )

        guard !mapped.notes.isEmpty else {
            throw DeckImportError.noVoiceSuitableCards(
                .init(
                    message: """
                    No voice-suitable cards found in “\(collection.primaryDeckName)”. \
                    \(report.summary). Image Occlusion cards can't be reviewed by voice.
                    """
                )
            )
        }

        let typeSummary = mapped.noteTypeCounts
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")

        return ImportedDeck(
            name: collection.primaryDeckName,
            description: "Imported from Anki · \(report.summary)"
                + (typeSummary.isEmpty ? "" : " · Types: \(typeSummary)"),
            source: .ankiImport,
            notes: mapped.notes,
            importReport: report
        )
    }

    /// Prefers modern zstd `collection.anki21b` (AnKing / AnkiHub exports) over the legacy stub `.anki2`.
    private func prepareCollectionDatabase(in directory: URL) throws -> URL {
        let preferredNames = [
            "collection.anki21b",
            "collection.anki21",
            "collection.anki2"
        ]

        var found: [String: URL] = [:]
        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                if preferredNames.contains(name) {
                    found[name] = fileURL
                }
            }
        }

        guard let sourceName = preferredNames.first(where: { found[$0] != nil }),
              let sourceURL = found[sourceName]
        else {
            throw DeckImportError.parsingFailed(
                "No collection.anki21b / collection.anki2 found in package."
            )
        }

        let data = try Data(contentsOf: sourceURL)
        if ZstdDecompressor.isZstd(data) {
            let decoded = try ZstdDecompressor.decompress(data)
            let outURL = directory.appendingPathComponent("collection.decoded.sqlite")
            try decoded.write(to: outURL, options: .atomic)
            return outURL
        }

        // Avoid the tiny compatibility stub when a real anki21b exists but failed detection.
        if sourceName == "collection.anki2", found["collection.anki21b"] != nil {
            throw DeckImportError.parsingFailed(
                "Found collection.anki21b but couldn't decompress it (zstd)."
            )
        }

        return sourceURL
    }
}

// MARK: - Sample importer

struct SampleDeckImporter: DeckImporter {
    var displayName: String { "Sample AnKing Decks" }

    func importDeck(from url: URL) async throws -> ImportedDeck {
        _ = url
        return SampleDeckCatalog.ankingStep1
    }

    func loadAllSampleDecks() -> [ImportedDeck] {
        SampleDeckCatalog.all
    }
}

// MARK: - Persistence

enum DeckPersistence {
    @MainActor
    static func persist(_ imported: ImportedDeck, into context: ModelContext) throws -> Deck {
        let deck = Deck(
            name: imported.name,
            deckDescription: imported.description,
            source: imported.source
        )

        for note in imported.notes {
            let cards: [Card]
            if note.cardType == .cloze || ClozeParser.containsCloze(note.front) {
                cards = ClozeParser.expandToCards(
                    noteText: note.front,
                    back: note.back,
                    tags: note.tags,
                    deckName: imported.name,
                    ankiNoteId: note.ankiNoteId,
                    oneByOne: note.oneByOne
                )
            } else {
                cards = [
                    Card(
                        front: note.front,
                        back: note.back,
                        tags: note.tags,
                        deckName: imported.name,
                        imageAttachments: note.imageAttachments,
                        cardType: .basic,
                        ankiNoteId: note.ankiNoteId
                    )
                ]
            }

            for card in cards {
                card.imageAttachments = note.imageAttachments
                card.deck = deck
                deck.cards.append(card)
            }
        }

        guard !deck.cards.isEmpty else {
            throw DeckImportError.emptyDeck
        }

        context.insert(deck)
        return deck
    }
}
