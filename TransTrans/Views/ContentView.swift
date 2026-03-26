import SwiftUI
import Translation
import os

private let logger = Logger(subsystem: "net.kcrt.app.transtrans", category: "ContentView")

struct ContentView: View {
    @State private var viewModel = SessionViewModel()
    @State private var subtitleController = SubtitleWindowController()

    var body: some View {
        HStack(spacing: 0) {
            // Main content: top-bottom split
            VStack(spacing: 0) {
                TranscriptPaneView(
                    lines: viewModel.sourceLines,
                    fontSize: viewModel.fontSize,
                    placeholder: viewModel.isSessionActive ? nil : String(localized: "Press \u{2318}R to start transcription")
                )
                Divider()

                if viewModel.displayMode == .multi {
                    ForEach(0..<viewModel.multiTargetCount, id: \.self) { slot in
                        if slot > 0 { Divider() }
                        multiTargetPane(slot: slot)
                    }
                } else {
                    TranscriptPaneView(
                        lines: viewModel.translationSlots[0].lines,
                        fontSize: viewModel.fontSize,
                        placeholder: viewModel.isSessionActive ? nil : String(localized: "Translation will appear here")
                    )
                }
            }

            Divider()

            // Right control strip
            ControlStripView(viewModel: viewModel)
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .frame(minWidth: 320, minHeight: viewModel.displayMode == .multi ? 320 : 200)
        .translationTask(viewModel.translationSlots.indices.contains(0) ? viewModel.translationSlots[0].config : nil) { session in
            await viewModel.handleTranslationSession(session, slot: 0)
        }
        .translationTask(viewModel.translationSlots.indices.contains(1) ? viewModel.translationSlots[1].config : nil) { session in
            await viewModel.handleTranslationSession(session, slot: 1)
        }
        .translationTask(viewModel.translationSlots.indices.contains(2) ? viewModel.translationSlots[2].config : nil) { session in
            await viewModel.handleTranslationSession(session, slot: 2)
        }
        .task {
            await viewModel.loadSupportedLocales()
        }
        .onAppear {
            setWindowLevel(viewModel.isAlwaysOnTop)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            // When the main window is restored from Dock, switch back to dual mode
            if let window = notification.object as? NSWindow,
               !(window is NSPanel),
               viewModel.displayMode == .subtitle {
                logger.info("Display mode → dual (reason: main window deminiaturized from Dock)")
                viewModel.displayMode = .dual
            }
        }
        .onChange(of: viewModel.isAlwaysOnTop) {
            setWindowLevel(viewModel.isAlwaysOnTop)
        }
        .onChange(of: viewModel.isSessionActive) {
            // Return to dual mode when the session stops
            if !viewModel.isSessionActive && viewModel.displayMode == .subtitle {
                logger.info("Display mode → dual (reason: session ended while in subtitle mode)")
                viewModel.displayMode = .dual
            }
        }
        .onChange(of: viewModel.displayMode) { oldValue, newValue in
            logger.info("Display mode changed: \(oldValue.rawValue) → \(newValue.rawValue)")
            if newValue == .subtitle {
                subtitleController.onDismiss = { [weak viewModel] in
                    logger.info("Display mode → dual (reason: subtitle overlay dismissed by user)")
                    viewModel?.displayMode = .dual
                }
                subtitleController.show(viewModel: viewModel)
                // Miniaturize the main window so only the subtitle overlay is visible
                mainWindow?.miniaturize(nil)
            } else if oldValue == .subtitle {
                subtitleController.close()
                // Restore the main window
                mainWindow?.deminiaturize(nil)
            }
        }
        .contextMenu {
            contextMenuItems
        }
        .focusable()
        .focusEffectDisabled()
        // Overlay invisible buttons for keyboard shortcuts
        .background {
            shortcutButtons
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert("Error", isPresented: showErrorBinding) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            viewModel.permissionIssue?.title ?? "",
            isPresented: showPermissionBinding
        ) {
            Button("Open System Settings") {
                viewModel.openSystemSettings()
                viewModel.permissionIssue = nil
            }
            Button("Cancel", role: .cancel) {
                viewModel.permissionIssue = nil
            }
        } message: {
            Text(viewModel.permissionIssue?.message ?? "")
        }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }

    private var showPermissionBinding: Binding<Bool> {
        Binding(
            get: { viewModel.permissionIssue != nil },
            set: { if !$0 { viewModel.permissionIssue = nil } }
        )
    }

    @ViewBuilder
    private func multiTargetPane(slot: Int) -> some View {
        let langId = slot < viewModel.multiTargetLanguageIdentifiers.count
            ? Locale.current.localizedString(forIdentifier: viewModel.multiTargetLanguageIdentifiers[slot])
                ?? viewModel.multiTargetLanguageIdentifiers[slot].uppercased()
            : "?"
        let lines = slot < viewModel.translationSlots.count ? viewModel.translationSlots[slot].lines : []
        TranscriptPaneView(
            lines: lines,
            fontSize: viewModel.fontSize,
            placeholder: viewModel.isSessionActive ? nil : langId
        )
    }

    @ViewBuilder
    private var shortcutButtons: some View {
        VStack {
            Button("Start/Stop") { viewModel.toggleSession() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Swap") { viewModel.swapLanguages() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Font+") { viewModel.increaseFontSize() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Font-") { viewModel.decreaseFontSize() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Pin") { viewModel.isAlwaysOnTop.toggle() }
                .keyboardShortcut("t", modifiers: .command)
            Button("SubtitleMode") {
                // Only allow entering subtitle mode when a session is active and in dual mode
                if viewModel.displayMode == .subtitle {
                    viewModel.displayMode = .dual
                } else if viewModel.isSessionActive && viewModel.displayMode == .dual {
                    viewModel.displayMode = .subtitle
                }
            }
                .keyboardShortcut("d", modifiers: .command)
            Button("MultiPane") {
                guard !viewModel.isSessionActive else { return }
                viewModel.displayMode = viewModel.displayMode == .multi ? .dual : .multi
            }
                .keyboardShortcut("m", modifiers: .command)
            Button("Save") {
                viewModel.saveTranscript(contentType: .both)
            }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.sourceLines.isEmpty && viewModel.translationSlots[0].lines.isEmpty)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Copy All (Original)") {
            copyToClipboard(viewModel.copyAllOriginal())
        }
        Button("Copy All (Translation)") {
            copyToClipboard(viewModel.copyAllTranslation())
        }
        Button("Copy All (Interleaved)") {
            copyToClipboard(viewModel.copyAllInterleaved())
        }
        Divider()
        Menu("Save Transcript") {
            Button("Original") {
                viewModel.saveTranscript(contentType: .original)
            }
            Button("Translation") {
                viewModel.saveTranscript(contentType: .translation)
            }
            Button("Both (Interleaved)") {
                viewModel.saveTranscript(contentType: .both)
            }
        }
        .disabled(viewModel.sourceLines.isEmpty && viewModel.translationSlots[0].lines.isEmpty)
        Divider()
        Button("Clear History") {
            viewModel.clearHistory()
        }
        .disabled(viewModel.isSessionActive)
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// The main application window (excludes subtitle overlay panels).
    private var mainWindow: NSWindow? {
        NSApplication.shared.windows.first { !($0 is NSPanel) }
    }

    private func setWindowLevel(_ alwaysOnTop: Bool) {
        guard let window = mainWindow else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}

#Preview {
    ContentView()
}
