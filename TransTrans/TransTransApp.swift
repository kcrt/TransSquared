import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// When the main WindowGroup window is closed, also close any auxiliary panels
    /// (e.g. subtitle overlay) so the app terminates properly.
    func applicationDidUpdate(_ notification: Notification) {
        let app = NSApplication.shared
        // Check if only non-activating panels remain (no regular windows).
        // A miniaturized window still counts as "present" — only truly invisible
        // (closed) windows should trigger panel cleanup.
        let hasRegularWindow = app.windows.contains { window in
            (window.isVisible || window.isMiniaturized) && !(window is NSPanel)
        }
        if !hasRegularWindow {
            // Close all remaining panels so applicationShouldTerminateAfterLastWindowClosed triggers
            for window in app.windows where window is NSPanel && window.isVisible {
                window.orderOut(nil)
            }
        }
    }
}

@main
struct TransTransApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let supportURL = URL(string: "https://github.com/kcrt/TransTrans")!

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 480, height: 240)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .help) {
                Link("TransTrans Support", destination: supportURL)
            }
        }
    }
}
