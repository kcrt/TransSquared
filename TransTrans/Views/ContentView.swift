import SwiftUI
import Translation
import AVFoundation
import UniformTypeIdentifiers
import os

private let logger = Logger.app("ContentView")

struct ContentView: View {
    @State private var viewModel = SessionViewModel()
    @State private var subtitleController = SubtitleWindowController()

    var body: some View {
        VStack(spacing: 0) {
            TranscriptPaneView(
                lines: viewModel.sourceLines,
                fontSize: viewModel.fontSize,
                placeholder: viewModel.isSessionActive ? nil : sourcePlaceholder
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
        let lines = slot < viewModel.translationSlots.count ? viewModel.translationSlots[slot].lines : []
        let placeholder: String? = viewModel.isSessionActive ? nil : (
            viewModel.targetCount == 1
                ? String(localized: "Translation will appear here")
                : langId
        )
        TranscriptPaneView(
            lines: lines,
            fontSize: viewModel.fontSize,
            placeholder: placeholder
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Group 1: Waveform + Rec/Stop + Mic (recording input)
        ToolbarItemGroup {
            Button {
                viewModel.toggleSession()
            } label: {
                HStack(spacing: 6) {
                    AudioWaveformView(levels: viewModel.audioLevels, isActive: viewModel.isSessionActive)
                        .frame(width: 60, height: 20)
                    Image(systemName: viewModel.isSessionActive ? "stop.fill" : "circle.fill")
                        .foregroundStyle(viewModel.isSessionActive ? .red : .pink)
                }
            }
            .help(viewModel.isSessionActive ? "Stop (⌘R)" : "Start (⌘R)")

            Menu {
                Button {
                    viewModel.selectedMicrophoneID = ""
                } label: {
                    CheckmarkLabel(title: "System Default", isSelected: viewModel.selectedMicrophoneID.isEmpty)
                }
                Divider()
                ForEach(viewModel.availableMicrophones, id: \.uniqueID) { device in
                    Button {
                        viewModel.selectedMicrophoneID = device.uniqueID
                    } label: {
                        CheckmarkLabel(title: device.localizedName, isSelected: viewModel.selectedMicrophoneID == device.uniqueID)
                    }
                }
            } label: {
                Label("Microphone", systemImage: "mic.fill")
            }
            .disabled(viewModel.isSessionActive)
            .help(microphoneHelpText)
        }

        // Group 2: Save + Clear
        ToolbarItemGroup {
            Menu {
                SaveTranscriptMenuItems(viewModel: viewModel)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.hasTranscriptContent)
            .help("Save Transcript (⌘S)")

            Button {
                viewModel.clearHistory()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(viewModel.isSessionActive || !viewModel.hasTranscriptContent)
            .help("Clear History")
        }

        ToolbarSpacer(.fixed)

        // Group 3: Display controls
        ToolbarItemGroup {
            Button {
                viewModel.toggleDisplayMode()
            } label: {
                Label(
                    viewModel.displayMode == .subtitle ? "Normal Mode" : "Subtitle Mode",
                    systemImage: viewModel.displayMode == .subtitle ? "captions.bubble.fill" : "captions.bubble"
                )
            }
            .disabled(subtitleButtonDisabled)
            .help(subtitleButtonHelp)

            Button {
                viewModel.isAlwaysOnTop.toggle()
            } label: {
                Label("Always on Top", systemImage: "pin.fill")
                    .foregroundStyle(viewModel.isAlwaysOnTop ? .orange : .secondary)
            }
            .help("Always on Top (⌘T)")
        }

        ToolbarSpacer(.fixed)

        // Group 4: Language controls
        ToolbarItemGroup {
            Menu {
                ForEach(viewModel.supportedSourceLocales, id: \.identifier) { locale in
                    Button {
                        logger.info("Source language selected: '\(locale.identifier)' (was '\(viewModel.sourceLocaleIdentifier)')")
                        viewModel.sourceLocaleIdentifier = locale.identifier
                        Task {
                            await viewModel.updateTargetLanguages()
                        }
                    } label: {
                        CheckmarkLabel(
                            title: locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                            isSelected: viewModel.sourceLocaleIdentifier == locale.identifier
                        )
                    }
                }
            } label: {
                Text(sourceLanguageLabel)
                    .fontWeight(.medium)
            }
            .disabled(viewModel.isSessionActive)
            .help("Source Language")

            if viewModel.targetCount == 1 {
                Button {
                    viewModel.swapLanguages()
                } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                .disabled(viewModel.isSessionActive)
                .help("Swap Languages (⌘⇧S)")
            } else {
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .help("Source → Target")
            }

            ForEach(0..<viewModel.targetCount, id: \.self) { slot in
                targetLanguageMenu(slot: slot)
            }

            if viewModel.targetCount < SessionViewModel.maxTargetCount {
                Button {
                    viewModel.addTargetLanguage()
                } label: {
                    Label("Add Language", systemImage: "plus.circle")
                }
                .disabled(viewModel.isSessionActive)
                .help("Add Target Language")
            }
            if viewModel.targetCount > 1 {
                Button {
                    viewModel.removeTargetLanguage()
                } label: {
                    Label("Remove Language", systemImage: "minus.circle")
                }
                .disabled(viewModel.isSessionActive)
                .help("Remove Target Language")
            }
        }

        ToolbarSpacer(.fixed)

        // Group 5: Font size
        ToolbarItemGroup {
            Button {
                viewModel.increaseFontSize()
            } label: {
                Label("Larger", systemImage: "textformat.size.larger")
            }
            .help("Increase Font Size (⌘+)")

            Button {
                viewModel.decreaseFontSize()
            } label: {
                Label("Smaller", systemImage: "textformat.size.smaller")
            }
            .help("Decrease Font Size (⌘-)")
        }

        ToolbarSpacer(.fixed)

        // Group 6: Settings
        ToolbarItem {
            Button {
                viewModel.showSettings.toggle()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .help("Settings")
        }
    }

    @ViewBuilder
    private func targetLanguageMenu(slot: Int) -> some View {
        let langId = viewModel.targetLanguageIdentifiers[slot]
        Menu {
            ForEach(viewModel.supportedTargetLanguages, id: \.minimalIdentifier) { language in
                Button {
                    logger.info("Target \(slot) selected: '\(language.minimalIdentifier)' (was '\(viewModel.targetLanguageIdentifiers[slot])')")
                    viewModel.targetLanguageIdentifiers[slot] = language.minimalIdentifier
                } label: {
                    CheckmarkLabel(
                        title: displayName(for: language),
                        isSelected: viewModel.targetLanguageIdentifiers[slot] == language.minimalIdentifier
                    )
                }
            }
        } label: {
            Text(langId.uppercased())
                .fontWeight(.medium)
        }
        .disabled(viewModel.isSessionActive)
        .help("Target Language \(slot + 1)")
    }

    private var sourceLanguageLabel: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return locale.language.minimalIdentifier.uppercased()
    }

    private var sourcePlaceholder: String {
        let langName = Locale.current.localizedString(forIdentifier: viewModel.sourceLocaleIdentifier)
            ?? viewModel.sourceLocaleIdentifier
        return String(localized: "Press \u{2318}R to start transcription of \(langName)")
    }

    private func displayName(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private var microphoneHelpText: String {
        if viewModel.selectedMicrophoneID.isEmpty {
            return "Microphone: System Default"
        }
        if let device = viewModel.selectedMicrophone {
            return "Microphone: \(device.localizedName)"
        }
        return "Microphone"
    }

    private var subtitleButtonDisabled: Bool {
        if viewModel.displayMode == .subtitle { return false }
        if !viewModel.isSessionActive { return true }
        return viewModel.targetCount > 1
    }

    private var subtitleButtonHelp: String {
        if viewModel.displayMode == .subtitle {
            return String(localized: "Normal Mode (⌘D)")
        }
        if viewModel.targetCount > 1 {
            return String(localized: "Subtitle mode is available only with a single destination language")
        }
        return String(localized: "Subtitle Mode (⌘D)")
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

// MARK: - Sheets & Alerts (extracted to reduce body complexity for the type-checker)

private struct SheetsAndAlerts: ViewModifier {
    @Bindable var viewModel: SessionViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showSettings) {
                SettingsView(viewModel: viewModel)
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
