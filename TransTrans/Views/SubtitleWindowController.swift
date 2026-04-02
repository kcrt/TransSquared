import AppKit
import SwiftUI

/// Manages a borderless, transparent overlay window that displays subtitle text
/// at the bottom of the main screen, like movie subtitles.
@MainActor
final class SubtitleWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<SubtitleOverlayView>?
    private var viewModel: SessionViewModel?

    /// Called when the user wants to exit subtitle mode (e.g. via ⌘D while overlay is shown).
    var onDismiss: (() -> Void)?

    func show(viewModel: SessionViewModel) {
        guard window == nil else { return }
        self.viewModel = viewModel

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
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        // Allow the panel to accept mouse events for text selection but not become key
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = makeSubtitleHostingView()
        self.hostingView = hosting
        panel.contentView = hosting
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

        // Keep content up-to-date using a periodic timer.
        // Update the existing hosting view's rootView instead of recreating it each tick.
        startUpdateTimer()
    }

    func close() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        updateTimer?.invalidate()
        updateTimer = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        viewModel = nil
    }

    var isVisible: Bool {
        window != nil
    }

    // MARK: - Private

    private var updateTimer: Timer?
    private var keyMonitor: Any?

    private func startUpdateTimer() {
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateContent()
            }
        }
    }

    private func updateContent() {
        guard let viewModel, let hostingView else { return }
        hostingView.rootView = SubtitleOverlayView(
            lines: viewModel.translationSlots.first?.lines ?? [],
            fontSize: viewModel.fontSize,
            now: Date(),
            onDismiss: { [weak self] in self?.onDismiss?() }
        )
    }

    private func makeSubtitleHostingView() -> NSHostingView<SubtitleOverlayView> {
        NSHostingView(
            rootView: SubtitleOverlayView(
                lines: viewModel?.translationSlots.first?.lines ?? [],
                fontSize: viewModel?.fontSize ?? 16,
                now: Date(),
                onDismiss: { [weak self] in self?.onDismiss?() }
            )
        )
    }
}
