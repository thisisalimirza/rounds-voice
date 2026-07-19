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

        // Only pull collection DBs — AnKing media can be gigabytes and isn't needed for voice.
        do {
            try ZipArchive.extract(
                archiveURL: localPackage,
                to: extractDir,
                onlyFileNames: [
                    "collection.anki21b",
                    "collection.anki21",
                    "collection.anki2"
                ]
            )
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
            let types = mapped.noteTypeCounts
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            throw DeckImportError.noVoiceSuitableCards(
                .init(
                    message: """
                    No voice-suitable cards found in “\(collection.primaryDeckName)”. \
                    \(report.summary). \
                    Note types seen: \(types.isEmpty ? "none" : types). \
                    Image Occlusion can't be reviewed by voice; if everything else was marked empty, field mapping failed — try re-exporting the .apkg from a current Anki (media optional).
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

        guard !found.isEmpty else {
            throw DeckImportError.parsingFailed(
                "No collection.anki21b / collection.anki2 found in package."
            )
        }

        // Prefer modern payloads; never fall back to the tiny stub `.anki2` when a newer
        // collection file exists but failed to decode.
        let candidates = preferredNames.compactMap { name -> (String, URL)? in
            guard let url = found[name] else { return nil }
            return (name, url)
        }

        var lastError: String?
        for (name, url) in candidates {
            // Skip the legacy stub whenever a modern file is also present.
            if name == "collection.anki2",
               found["collection.anki21b"] != nil || found["collection.anki21"] != nil {
                continue
            }

            do {
                return try decodeCollectionFile(named: name, at: url, into: directory)
            } catch let error as DeckImportError {
                lastError = error.errorDescription
            } catch {
                lastError = error.localizedDescription
            }
        }

        throw DeckImportError.parsingFailed(
            lastError ?? "Couldn't decode any collection database in the package."
        )
    }

    private func decodeCollectionFile(named sourceName: String, at sourceURL: URL, into directory: URL) throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = attrs[.size] as? NSNumber ?? 0
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        let sqliteMagic = Data("SQLite format 3".utf8)

        if data.isEmpty || fileSize.intValue == 0 {
            throw DeckImportError.parsingFailed(
                "\(sourceName) is empty (0 bytes) after unzip — ZIP64 / extract failed."
            )
        }

        if ZstdDecompressor.isZstd(data) {
            let outURL = directory.appendingPathComponent("collection.decoded.sqlite")
            try ZstdDecompressor.decompressToFile(data, destination: outURL)
            // Validate header without loading the whole DB into RAM.
            let handle = try FileHandle(forReadingFrom: outURL)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 16) ?? Data()
            guard header.starts(with: sqliteMagic) else {
                throw DeckImportError.parsingFailed(
                    "Decompressed \(sourceName) is not a SQLite database."
                )
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?
                .intValue ?? 0
            if size < 4_096 {
                throw DeckImportError.parsingFailed(
                    "Decompressed \(sourceName) is suspiciously small (\(size) bytes)."
                )
            }
            return outURL
        }

        if data.starts(with: sqliteMagic) {
            if data.count < 4_096, sourceName != "collection.anki2" {
                throw DeckImportError.parsingFailed(
                    "\(sourceName) SQLite is suspiciously small (\(data.count) bytes)."
                )
            }
            return sourceURL
        }

        let hex = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        throw DeckImportError.parsingFailed(
            "\(sourceName) is neither zstd nor SQLite (size \(data.count), first bytes: \(hex))."
        )
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
    /// Small decks / samples.
    @MainActor
    static func persist(_ imported: ImportedDeck, into context: ModelContext) throws -> Deck {
        try persistBatched(imported, into: context, batchSize: 500, onProgress: nil)
    }

    /// Persist in batches so a full AnKing import doesn't get jetsam'd (signal 9).
    @MainActor
    static func persist(
        _ imported: ImportedDeck,
        into context: ModelContext,
        batchSize: Int,
        onProgress: ((Int, Int) -> Void)?
    ) async throws -> Deck {
        let deck = Deck(
            name: imported.name,
            deckDescription: imported.description,
            source: imported.source
        )
        context.insert(deck)

        let total = imported.notes.count
        var index = 0
        while index < total {
            let end = min(index + max(batchSize, 1), total)
            try autoreleasepool {
                for note in imported.notes[index..<end] {
                    append(note: note, to: deck, importedName: imported.name, context: context)
                }
                try context.save()
            }
            index = end
            onProgress?(index, total)
            await Task.yield()
        }

        guard !deck.cards.isEmpty else {
            throw DeckImportError.emptyDeck
        }
        return deck
    }

    @MainActor
    private static func persistBatched(
        _ imported: ImportedDeck,
        into context: ModelContext,
        batchSize: Int,
        onProgress: ((Int, Int) -> Void)?
    ) throws -> Deck {
        let deck = Deck(
            name: imported.name,
            deckDescription: imported.description,
            source: imported.source
        )
        context.insert(deck)

        let total = imported.notes.count
        var index = 0
        while index < total {
            let end = min(index + max(batchSize, 1), total)
            try autoreleasepool {
                for note in imported.notes[index..<end] {
                    append(note: note, to: deck, importedName: imported.name, context: context)
                }
                try context.save()
            }
            index = end
            onProgress?(index, total)
        }

        guard !deck.cards.isEmpty else {
            throw DeckImportError.emptyDeck
        }
        return deck
    }

    @MainActor
    private static func append(
        note: ImportedNote,
        to deck: Deck,
        importedName: String,
        context: ModelContext
    ) {
        let cards: [Card]
        if note.cardType == .cloze || ClozeParser.containsCloze(note.front) {
            cards = ClozeParser.expandToCards(
                noteText: note.front,
                back: note.back,
                tags: note.tags,
                deckName: importedName,
                ankiNoteId: note.ankiNoteId,
                oneByOne: note.oneByOne
            )
        } else {
            cards = [
                Card(
                    front: note.front,
                    back: note.back,
                    tags: note.tags,
                    deckName: importedName,
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
            context.insert(card)
        }
    }
}
