import SwiftUI
import SwiftData

@main
struct RoundsVoiceApp: App {
    private let container: ModelContainer

    init() {
        do {
            let schema = Schema([Deck.self, Card.self])
            let configuration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false
            )
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(RVTheme.seafoam)
        }
        .modelContainer(container)
    }
}
