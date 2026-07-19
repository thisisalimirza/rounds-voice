import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class DeckImportViewModel {
    var isImporting = false
    var progressMessage: String?
    var lastReport: ImportedDeck.ImportReport?
    var errorMessage: String?
    var successMessage: String?

    private let importer = AnkiDeckImporter()

    func importPackage(from url: URL, into context: ModelContext) async {
        isImporting = true
        progressMessage = "Reading Anki package…"
        errorMessage = nil
        successMessage = nil
        lastReport = nil
        defer {
            isImporting = false
            progressMessage = nil
        }

        do {
            progressMessage = "Parsing notes & AnKing note types…"
            // Reminder is also on the import overlay — keep progress copy honest.
            let imported = try await importer.importDeck(from: url)
            lastReport = imported.importReport

            let totalNotes = imported.notes.count
            progressMessage = "Saving 0 / \(totalNotes) notes — keep the app open…"

            let deck = try await DeckPersistence.persist(
                imported,
                into: context,
                batchSize: 200,
                onProgress: { [weak self] done, total in
                    self?.progressMessage = "Saving \(done) / \(total) notes — keep the app open…"
                }
            )

            let cardCount = deck.totalCardCount
            successMessage = "Imported “\(deck.name)” · \(cardCount) voice cards"
                + (imported.importReport.map { " · \($0.summary)" } ?? "")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
