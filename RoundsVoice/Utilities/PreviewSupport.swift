import Foundation
import SwiftData

/// In-memory SwiftData container for SwiftUI previews.
enum PreviewSupport {
    @MainActor
    static let container: ModelContainer = {
        let schema = Schema([Deck.self, Card.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            for imported in SampleDeckCatalog.all {
                _ = try? DeckPersistence.persist(imported, into: context)
            }
            return container
        } catch {
            fatalError("Preview container failed: \(error)")
        }
    }()
}
