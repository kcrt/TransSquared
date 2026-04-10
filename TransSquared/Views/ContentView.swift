import SwiftUI
import Translation
import AVFoundation
import UniformTypeIdentifiers
import os

private let logger = Logger.app("ContentView")

struct ContentView: View {
    @State var viewModel = SessionViewModel()
    @State var subtitleController = SubtitleWindowController()

    var body: some View {
        VStack(spacing: 0) {
            TranscriptPaneView(
                lines: viewModel.sourceLines,
                fontSize: viewModel.fontSize,
                placeholder: viewModel.isSessionActive ? nil : sourcePlaceholder,
                showElapsedTime: true,
                isEditable: viewModel.displayMode == .normal,
                onLineEdited: { id, newText in
                    viewModel.editSourceLine(id: id, newText: newText)
                },
                onTimestampTapped: toggleHighlight,
                highlightedSentenceID: viewModel.highlightedSentenceID,
                canPlayback: viewModel.hasRecording && !viewModel.isSessionActive,
                playingEntryID: viewModel.playbackService?.playingEntryID,
                onPlayFromTimestamp: { elapsed, entryID in
                    viewModel.playFromTimestamp(elapsed, entryID: entryID)
                }
            )
            .environment(\.layoutDirection, layoutDirection(for: viewModel.sourceLocaleIdentifier))
            Divider()

            ForEach(0..<viewModel.targetCount, id: \.self) { slot in
                if slot > 0 { Divider() }
                targetPane(slot: slot)
            }
        }
        .frame(minWidth: 320, minHeight: viewModel.targetCount > 1 ? 320 : 200)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("Trans²")
                    .font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
            toolbarContent
        }
        .modifier(TranslationTaskSlots(viewModel: viewModel))
        .modifier(TranslationPreparation(viewModel: viewModel))
        .task {
            await viewModel.loadSupportedLocales()
        }
        .onAppear {
            setWindowLevel(viewModel.isAlwaysOnTop)
            viewModel.refreshMicrophones()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await viewModel.refreshTranslationInstallStatus()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            // When the main window is restored from Dock, switch back to normal mode
            if let window = notification.object as? NSWindow,
               !(window is NSPanel),
               viewModel.displayMode == .subtitle {
                logger.info("Display mode → normal (reason: main window deminiaturized from Dock)")
                viewModel.displayMode = .normal
            }
        }
        .onChange(of: viewModel.isAlwaysOnTop) {
            setWindowLevel(viewModel.isAlwaysOnTop)
        }
        .onChange(of: viewModel.isSessionActive) {
            // Return to normal mode when the session stops
            if !viewModel.isSessionActive && viewModel.displayMode == .subtitle {
                logger.info("Display mode → normal (reason: session ended while in subtitle mode)")
                viewModel.displayMode = .normal
            }
        }
        .onChange(of: viewModel.displayMode) { oldValue, newValue in
            logger.info("Display mode changed: \(oldValue.rawValue) → \(newValue.rawValue)")
            if newValue == .subtitle {
                subtitleController.onDismiss = { [weak viewModel] in
                    logger.info("Display mode → normal (reason: subtitle overlay dismissed by user)")
                    viewModel?.displayMode = .normal
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
        .focusedSceneValue(viewModel)
        .focusable()
        .focusEffectDisabled()
        .modifier(SheetsAndAlerts(viewModel: viewModel))
    }

    @ViewBuilder
    private func targetPane(slot: Int) -> some View {
        let langId = targetLanguageDisplayName(slot: slot)
        let lines = viewModel.translationLines(forSlot: slot)
        let placeholder: String? = viewModel.isSessionActive ? nil : (
            viewModel.targetCount == 1
                ? String(localized: "Translation will appear here")
                : langId
        )
        TranscriptPaneView(
            lines: lines,
            fontSize: viewModel.fontSize,
            placeholder: placeholder,
            showElapsedTime: true,
            isEditable: viewModel.displayMode == .normal,
            animateTextChanges: true,
            onLineEdited: { id, newText in
                viewModel.editTranslationLine(slot: slot, id: id, newText: newText)
            },
            onTimestampTapped: toggleHighlight,
            highlightedSentenceID: viewModel.highlightedSentenceID,
            canPlayback: true,
            playingEntryID: viewModel.speechSynthesisService.speakingEntryID,
            onPlayFromTimestamp: { _, entryID in
                viewModel.speakTranslation(entryID: entryID, slot: slot)
            }
        )
        .environment(\.layoutDirection, layoutDirection(for: viewModel.targetLanguageIdentifiers[slot]))
    }

    private func toggleHighlight(_ sentenceID: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            viewModel.highlightedSentenceID =
                viewModel.highlightedSentenceID == sentenceID ? nil : sentenceID
        }
    }

    private func targetLanguageDisplayName(slot: Int) -> String {
        guard slot < viewModel.targetLanguageIdentifiers.count else { return "?" }
        let id = viewModel.targetLanguageIdentifiers[slot]
        return Locale.current.localizedString(forIdentifier: id) ?? id.uppercased()
    }

    var sourcePlaceholder: String {
        let langName = Locale.current.localizedString(forIdentifier: viewModel.sourceLocaleIdentifier)
            ?? viewModel.sourceLocaleIdentifier
        return String(localized: "Press \u{2318}R to start transcription of \(langName)")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(String(localized: "Copy All (Original)", comment: "Context menu item to copy all original transcription")) {
            NSPasteboard.general.copyString(viewModel.copyAllOriginal())
        }
        Button(String(localized: "Copy All (Translation)", comment: "Context menu item to copy all translated text")) {
            NSPasteboard.general.copyString(viewModel.copyAllTranslation())
        }
        Button(String(localized: "Copy All (Interleaved)", comment: "Context menu item to copy original and translation interleaved")) {
            NSPasteboard.general.copyString(viewModel.copyAllInterleaved())
        }
        Divider()
        Menu(String(localized: "Save Transcript", comment: "Context menu item to save transcript")) {
            SaveTranscriptMenuItems(viewModel: viewModel)
        }
        .disabled(!viewModel.hasTranscriptContent)
        Divider()
        Button(String(localized: "Clear History", comment: "Context menu item to clear all transcript history")) {
            viewModel.clearHistory()
        }
        .disabled(viewModel.isSessionActive)
    }

    /// The main application window (excludes subtitle overlay panels).
    private var mainWindow: NSWindow? {
        NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first { !($0 is NSPanel) }
    }

    private func layoutDirection(for localeIdentifier: String) -> LayoutDirection {
        Locale.Language(identifier: localeIdentifier).characterDirection == .rightToLeft
            ? .rightToLeft : .leftToRight
    }

    private func setWindowLevel(_ alwaysOnTop: Bool) {
        guard let window = mainWindow else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}

// MARK: - Translation Task Slots (extracted to reduce body complexity for the type-checker)

/// Attaches one `.translationTask` modifier per translation slot, driven by `maxTranslationSlots`.
private struct TranslationTaskSlots: ViewModifier {
    var viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content
            .background {
                ForEach(0..<TranscriptEntry.maxTranslationSlots, id: \.self) { slot in
                    Color.clear
                        .translationTask(slotConfig(slot)) { session in
                            await viewModel.handleTranslationSession(session, slot: slot)
                        }
                }
            }
    }

    private func slotConfig(_ slot: Int) -> TranslationSession.Configuration? {
        slot < viewModel.translationConfigs.count ? viewModel.translationConfigs[slot] : nil
    }
}

// MARK: - Translation Model Preparation (proactive download trigger)

/// Attaches a `.translationTask` for proactively preparing (downloading) translation models
/// when the user selects a target language that is not yet installed.
private struct TranslationPreparation: ViewModifier {
    var viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content
            .translationTask(viewModel.translationPreparationConfig) { session in
                await viewModel.handleTranslationPreparationSession(session)
            }
    }
}

// MARK: - Sheets & Alerts (extracted to reduce body complexity for the type-checker)

private struct SheetsAndAlerts: ViewModifier {
    @Bindable var viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isTranscribingFile, onDismiss: {
                viewModel.cancelFileTranscription()
            }) {
                FileTranscriptionProgressView(viewModel: viewModel)
            }
            .fileImporter(
                isPresented: $viewModel.showFileImporter,
                allowedContentTypes: [.wav, .mp3, .mpeg4Audio, .aiff, .audio],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    viewModel.requestFileTranscription(url: url)
                }
            }
            .alert(
                String(localized: "Existing Data Will Be Cleared",
                       comment: "Title of confirmation alert when starting file transcription with existing transcript data"),
                isPresented: $viewModel.showFileTranscriptionConfirmation
            ) {
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    viewModel.pendingFileTranscriptionURL = nil
                }
                Button(String(localized: "OK", comment: "OK button to confirm clearing data")) {
                    viewModel.confirmFileTranscription()
                }
            } message: {
                Text("Starting a new file transcription will clear the current transcript and translation data.",
                     comment: "Message explaining that existing data will be lost when starting file transcription")
            }
            .fileExporter(
                isPresented: $viewModel.isExporterPresented,
                item: viewModel.exportContent,
                contentTypes: viewModel.exportContentTypes,
                defaultFilename: viewModel.exportDefaultFilename
            ) { result in
                switch result {
                case .success(let url):
                    logger.info("Transcript exported to \(url.path)")
                case .failure(let error):
                    logger.error("Failed to export transcript: \(error.localizedDescription)")
                    viewModel.errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
            .alert("Error", isPresented: showErrorBinding) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert(
                viewModel.permissionIssue?.title ?? "",
                isPresented: $viewModel.permissionIssue.isNotNil(),
                presenting: viewModel.permissionIssue
            ) { _ in
                Button("Open System Settings") {
                    viewModel.openSystemSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: { issue in
                Text(issue.message)
            }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private extension Binding {
    /// Creates a `Binding<Bool>` that is `true` when the wrapped optional is non-nil.
    /// Setting it to `false` sets the wrapped value to `nil`.
    func isNotNil<T>() -> Binding<Bool> where Value == T? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } }
        )
    }
}

#Preview {
    ContentView()
}
