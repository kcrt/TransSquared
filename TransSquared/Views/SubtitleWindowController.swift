import AppKit
import SwiftUI

/// Manages a borderless, transparent overlay window that displays subtitle text
/// at the bottom of the main screen, like movie subtitles.
///
/// UI updates are driven entirely by SwiftUI's `@Observable` tracking and
/// `TimelineView` (see `SubtitleContainerView`), so no manual observation
/// machinery or timers are needed.
@MainActor
final class SubtitleWindowController {
    private var window: NSWindow?
    private var keyMonitor: Any?

    /// Called when the user wants to exit subtitle mode (e.g. via ⌘D while overlay is shown).
    var onDismiss: (@MainActor () -> Void)?

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    func show(viewModel: SessionViewModel) {
        guard window == nil else { return }

        guard let screen = NSScreen.main else { return }
        // Use visibleFrame to avoid overlapping the Dock and menu bar
        let visible = screen.visibleFrame

        let overlayHeight: CGFloat = 200
        let windowFrame = NSRect(
            x: visible.origin.x,
            y: visible.origin.y,
            width: visible.width,
            height: overlayHeight
        )

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating  // Above normal windows but below system UI
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        panel.contentView = NSHostingView(
            rootView: SubtitleContainerView(viewModel: viewModel)
        )
        panel.orderFrontRegardless()

        self.window = panel

        // Monitor ⌘D globally so the user can exit subtitle mode even when the main window is miniaturized
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "d" {
                self?.onDismiss?()
                return nil  // consume the event
            }
            return event
        }
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    var isVisible: Bool {
        window != nil
    }
}
