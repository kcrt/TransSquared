import AppKit
import Observation
import os
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

    nonisolated deinit {
        updateTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

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
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

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

        // Observe ViewModel changes reactively and refresh periodically for subtitle expiration.
        startObserving()
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
    /// Whether an observation-triggered update is already scheduled.
    /// Accessed from the arbitrary thread where `onChange` fires, so it
    /// needs its own synchronization.
    private nonisolated let updateScheduled = OSAllocatedUnfairLock(initialState: false)

    private func startObserving() {
        observeViewModel()
        // Periodic timer only for refreshing `now` to expire old subtitle lines (1s is sufficient).
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateContent()
            }
        }
    }

    /// Reactively updates subtitle content when ViewModel properties change.
    /// Uses a coalescing flag so rapid-fire changes batch into a single update
    /// per run-loop cycle instead of spawning a new Task per change.
    private func observeViewModel() {
        guard viewModel != nil, hostingView != nil else { return }
        withObservationTracking {
            updateContent()
        } onChange: { [weak self] in
            guard let self else { return }
            let alreadyScheduled = self.updateScheduled.withLock { scheduled -> Bool in
                if scheduled { return true }
                scheduled = true
                return false
            }
            guard !alreadyScheduled else { return }
            Task { @MainActor in
                self.updateScheduled.withLock { $0 = false }
                self.observeViewModel()
            }
        }
    }

    private func updateContent() {
        guard let viewModel, let hostingView else { return }
        hostingView.rootView = SubtitleOverlayView(
            lines: viewModel.translationLines(forSlot: 0),
            fontSize: viewModel.fontSize,
            now: Date()
        )
    }

    private func makeSubtitleHostingView() -> NSHostingView<SubtitleOverlayView> {
        NSHostingView(
            rootView: SubtitleOverlayView(
                lines: viewModel?.translationLines(forSlot: 0) ?? [],
                fontSize: viewModel?.fontSize ?? 16,
                now: Date()
            )
        )
    }
}
