import Foundation
import Testing
@testable import RoundsVoice

struct AnKingPackageIntegrationTests {
    /// Verifies the user's real AnKing Step Deck.apkg when present on disk.
    @Test func importsAnKingStepDeckPackage() async throws {
        let url = URL(fileURLWithPath: "/Users/alimirza/Downloads/AnKing Step Deck.apkg")
        try #require(FileManager.default.fileExists(atPath: url.path), "AnKing Step Deck.apkg not found in Downloads")

        let imported = try await AnkiDeckImporter().importDeck(from: url)

        #expect(imported.name.contains("AnKing"))
        #expect(imported.source == .ankiImport)
        #expect(imported.notes.count > 20_000)

        let report = try #require(imported.importReport)
        #expect(report.skippedImageOcclusion == 5)
        #expect(report.importedNotes == report.totalAnkiNotes - report.skippedImageOcclusion - report.skippedEmpty - report.skippedUnsupportedType)

        // Cloze-heavy deck
        let clozeNotes = imported.notes.filter { $0.cardType == .cloze }
        #expect(clozeNotes.count > 20_000)

        // One-by-one / shared-cN sequential cards expand past note count
        let cards = clozeNotes.flatMap {
            ClozeParser.expandToCards(
                noteText: $0.front,
                back: $0.back,
                tags: $0.tags,
                deckName: imported.name,
                ankiNoteId: $0.ankiNoteId,
                oneByOne: $0.oneByOne
            )
        }
        #expect(cards.count > imported.notes.count)
        #expect(cards.contains { $0.clozeOrdinal != nil })

        // Spot-check a sequential spoken chain
        if let sequential = cards.first(where: { $0.clozeOrdinal == 1 }) {
            #expect(!sequential.spokenQuestion.isEmpty)
            #expect(!sequential.spokenAnswer.isEmpty)
        }
    }
}
