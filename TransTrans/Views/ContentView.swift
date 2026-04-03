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
                onTimestampTapped: { sentenceID in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.highlightedSentenceID =
                            viewModel.highlightedSentenceID == sentenceID ? nil : sentenceID
                    }
                },
                highlightedSentenceID: viewModel.highlightedSentenceID,
                canPlayback: viewModel.hasRecording,
                playingEntryID: viewModel.playbackService?.playingEntryID,
                onPlayFromTimestamp: { elapsed, entryID in
                    viewModel.playFromTimestamp(elapsed, entryID: entryID)
                }
            )
            Divider()

            ForEach(0..<viewModel.targetCount, id: \.self) { slot in
                if slot > 0 { Divider() }
                targetPane(slot: slot)
            }
        }
        .frame(minWidth: 320, minHeight: viewModel.targetCount > 1 ? 320 : 200)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text("TransTrans")
                    .font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
            toolbarContent
        }
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
            viewModel.refreshMicrophones()
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
        let langId = slot < viewModel.targetLanguageIdentifiers.count
            ? Locale.current.localizedString(forIdentifier: viewModel.targetLanguageIdentifiers[slot])
                ?? viewModel.targetLanguageIdentifiers[slot].uppercased()
            : "?"
        let lines = viewModel.translationLines(forSlot: slot)
        let placeholder: String? = viewModel.isSessionActive ? nil : (
            viewModel.targetCount == 1
                ? String(localized: "Translation will appear here")
                : langId
        )
        let capturedSlot = slot
        TranscriptPaneView(
            lines: lines,
            fontSize: viewModel.fontSize,
            placeholder: placeholder,
            showElapsedTime: true,
            isEditable: viewModel.displayMode == .normal,
            onLineEdited: { id, newText in
                viewModel.editTranslationLine(slot: capturedSlot, id: id, newText: newText)
            },
            onTimestampTapped: { sentenceID in
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.highlightedSentenceID =
                        viewModel.highlightedSentenceID == sentenceID ? nil : sentenceID
                }
            },
            highlightedSentenceID: viewModel.highlightedSentenceID,
            canPlayback: true,
            playingEntryID: viewModel.speechSynthesisService.speakingEntryID,
            onPlayFromTimestamp: { _, entryID in
                viewModel.speakTranslation(entryID: entryID, slot: capturedSlot)
            }
        )
    }

    var sourcePlaceholder: String {
        let langName = Locale.current.localizedString(forIdentifier: viewModel.sourceLocaleIdentifier)
            ?? viewModel.sourceLocaleIdentifier
        return String(localized: "Press \u{2318}R to start transcription of \(langName)")
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
            SaveTranscriptMenuItems(viewModel: viewModel)
        }
        .disabled(!viewModel.hasTranscriptContent)
        Divider()
        Button("Clear History") {
            viewModel.clearHistory()
        }
        .disabled(viewModel.isSessionActive)
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
                contentTypes: [.plainText],
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
            .alert(
                String(localized: "Recording Will Be Deleted",
                       comment: "Title of confirmation alert when switching session mode with existing recording"),
                isPresented: $viewModel.showModeSwitchConfirmation
            ) {
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {
                    viewModel.pendingModeSwitch = nil
                }
                Button(String(localized: "OK", comment: "OK button to confirm mode switch")) {
                    viewModel.confirmModeSwitch()
                }
            } message: {
                Text("Switching modes will delete the current audio recording.",
                     comment: "Message explaining that the recording will be lost when switching session mode")
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
}

#Preview {
    ContentView()
}
