import SwiftUI
import SwiftData

@main
struct TransTransApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TranscriptionSession.self,
            Segment.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Make the window background transparent so the frosted glass effect shows through
                    if let window = NSApplication.shared.windows.first {
                        window.isOpaque = false
                        window.backgroundColor = .clear
                    }
                }
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 480, height: 240)
        .windowResizability(.contentSize)
    }
}
