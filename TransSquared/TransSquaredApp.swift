import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// When the main WindowGroup window is closed, also close any auxiliary panels
    /// (e.g. subtitle overlay) so the app terminates properly.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable window tabbing — this app uses a single window, so
        // the "Show Tab Bar" menu item is unnecessary.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Observe window close events so we can clean up orphaned panels.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    @objc private func windowDidClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              !(closedWindow is NSPanel) else { return }

        // After a regular window closes, check if any regular windows remain.
        // Dispatch async so the window list has been updated.
        DispatchQueue.main.async {
            let app = NSApplication.shared
            let hasRegularWindow = app.windows.contains { window in
                (window.isVisible || window.isMiniaturized) && !(window is NSPanel)
            }
            if !hasRegularWindow {
                for window in app.windows where window is NSPanel && window.isVisible {
                    window.orderOut(nil)
                }
            }
        }
    }
}

@main
struct TransSquaredApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 480, height: 240)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            AppMenuCommands()
        }
    }
}
