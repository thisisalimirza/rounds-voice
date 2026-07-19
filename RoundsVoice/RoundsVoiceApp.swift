import SwiftUI
import SwiftData
import MediaPlayer

@main
struct RoundsVoiceApp: App {
    private let container: ModelContainer

    init() {
        // Warm remote command center so AirPods / lock screen can attach quickly.
        _ = NowPlayingSession.shared
        _ = ContinuousAudioSession.shared

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
