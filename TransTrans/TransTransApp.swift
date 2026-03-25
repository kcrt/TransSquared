import SwiftUI

@main
struct TransTransApp: App {
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
        .defaultSize(width: 480, height: 240)
        .windowResizability(.contentSize)
    }
}
