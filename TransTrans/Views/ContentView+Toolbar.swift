import SwiftUI
import AVFoundation
import os

private let logger = Logger.app("ContentView")

// MARK: - Toolbar

extension ContentView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
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

    // MARK: - Target Language Menu

    @ViewBuilder
    func targetLanguageMenu(slot: Int) -> some View {
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

    // MARK: - Toolbar Helpers

    var sourceLanguageLabel: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return locale.language.minimalIdentifier.uppercased()
    }

    var microphoneHelpText: String {
        if viewModel.selectedMicrophoneID.isEmpty {
            return "Microphone: System Default"
        }
        if let device = viewModel.selectedMicrophone {
            return "Microphone: \(device.localizedName)"
        }
        return "Microphone"
    }

    var subtitleButtonDisabled: Bool {
        if viewModel.displayMode == .subtitle { return false }
        if !viewModel.isSessionActive { return true }
        return viewModel.targetCount > 1
    }

    var subtitleButtonHelp: String {
        if viewModel.displayMode == .subtitle {
            return String(localized: "Normal Mode (⌘D)")
        }
        if viewModel.targetCount > 1 {
            return String(localized: "Subtitle mode is available only with a single destination language")
        }
        return String(localized: "Subtitle Mode (⌘D)")
    }

    func displayName(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}
