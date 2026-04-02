import SwiftUI
import AVFoundation

// MARK: - App Menu Commands

struct AppMenuCommands: Commands {
    @FocusedValue(SessionViewModel.self) private var viewModel

    var body: some Commands {
        // App menu: Settings
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                viewModel?.showSettings = true
            }
            .keyboardShortcut(",")
            .disabled(viewModel == nil)
        }

        // File menu: Save transcript
        CommandGroup(replacing: .saveItem) {
            Button("Save Original...") {
                viewModel?.saveTranscript(contentType: .original)
            }
            .disabled(viewModel?.hasTranscriptContent != true)

            Button("Save Translation...") {
                viewModel?.saveTranscript(contentType: .translation)
            }
            .disabled(viewModel?.hasTranscriptContent != true)

            Button("Save Both (Interleaved)...") {
                viewModel?.saveTranscript(contentType: .both)
            }
            .keyboardShortcut("s")
            .disabled(viewModel?.hasTranscriptContent != true)
        }

        // Edit menu: Copy and Clear
        CommandGroup(after: .pasteboard) {
            Section {
                Button("Copy All (Original)") {
                    copyToClipboard(viewModel?.copyAllOriginal())
                }
                .disabled(viewModel?.hasTranscriptContent != true)

                Button("Copy All (Translation)") {
                    copyToClipboard(viewModel?.copyAllTranslation())
                }
                .disabled(viewModel?.hasTranscriptContent != true)

                Button("Copy All (Interleaved)") {
                    copyToClipboard(viewModel?.copyAllInterleaved())
                }
                .disabled(viewModel?.hasTranscriptContent != true)
            }

            Section {
                Button("Clear History") {
                    viewModel?.clearHistory()
                }
                .disabled(viewModel == nil
                    || viewModel!.isSessionActive
                    || !viewModel!.hasTranscriptContent)
            }
        }

        // View menu: Font size and display toggles
        CommandGroup(after: .toolbar) {
            Section {
                Button("Increase Font Size") {
                    viewModel?.increaseFontSize()
                }
                .keyboardShortcut("+")
                .disabled(viewModel == nil)

                Button("Decrease Font Size") {
                    viewModel?.decreaseFontSize()
                }
                .keyboardShortcut("-")
                .disabled(viewModel == nil)
            }

            Section {
                Toggle("Always on Top", isOn: alwaysOnTopBinding)
                    .keyboardShortcut("t")
                    .disabled(viewModel == nil)

                Toggle(subtitleModeLabel, isOn: subtitleModeBinding)
                    .keyboardShortcut("d")
                    .disabled(subtitleButtonDisabled)
            }
        }

        // Custom Transcription menu
        CommandMenu("Transcription") {
            Button(viewModel?.isSessionActive == true
                ? "Stop Recording" : "Start Recording"
            ) {
                viewModel?.toggleSession()
            }
            .keyboardShortcut("r")
            .disabled(viewModel == nil)

            Divider()

            // Source Language submenu
            sourceLanguageMenu

            // Target Language submenus (one per active slot)
            targetLanguageMenus

            Button("Swap Languages") {
                viewModel?.swapLanguages()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(viewModel == nil || viewModel!.isSessionActive)

            Divider()

            Button("Add Target Language") {
                viewModel?.addTargetLanguage()
            }
            .disabled(viewModel == nil
                || viewModel!.isSessionActive
                || viewModel!.targetCount >= SessionViewModel.maxTargetCount)

            Button("Remove Target Language") {
                viewModel?.removeTargetLanguage()
            }
            .disabled(viewModel == nil
                || viewModel!.isSessionActive
                || viewModel!.targetCount <= 1)

            Divider()

            // Microphone submenu
            microphoneMenu
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Link("TransTrans Support",
                 destination: URL(string: "https://github.com/kcrt/TransTrans")!)
        }
    }

    // MARK: - Submenus

    @ViewBuilder
    private var sourceLanguageMenu: some View {
        Menu("Source Language") {
            if let vm = viewModel {
                ForEach(vm.supportedSourceLocales, id: \.identifier) { locale in
                    Button {
                        vm.sourceLocaleIdentifier = locale.identifier
                        Task {
                            await vm.updateTargetLanguages()
                        }
                    } label: {
                        CheckmarkLabel(
                            title: locale.localizedString(forIdentifier: locale.identifier)
                                ?? locale.identifier,
                            isSelected: vm.sourceLocaleIdentifier == locale.identifier
                        )
                    }
                }
            }
        }
        .disabled(viewModel == nil || viewModel!.isSessionActive)
    }

    @ViewBuilder
    private var targetLanguageMenus: some View {
        if let vm = viewModel {
            ForEach(0..<vm.targetCount, id: \.self) { slot in
                Menu(vm.targetCount == 1
                    ? "Target Language"
                    : "Target Language \(slot + 1)"
                ) {
                    ForEach(vm.supportedTargetLanguages, id: \.minimalIdentifier) { language in
                        Button {
                            vm.targetLanguageIdentifiers[slot] = language.minimalIdentifier
                        } label: {
                            CheckmarkLabel(
                                title: Locale.current.localizedString(
                                    forIdentifier: language.minimalIdentifier
                                ) ?? language.minimalIdentifier,
                                isSelected: vm.targetLanguageIdentifiers[slot]
                                    == language.minimalIdentifier
                            )
                        }
                    }
                }
                .disabled(vm.isSessionActive)
            }
        }
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        Menu("Microphone") {
            if let vm = viewModel {
                Button {
                    vm.selectedMicrophoneID = ""
                } label: {
                    CheckmarkLabel(
                        title: String(localized: "System Default"),
                        isSelected: vm.selectedMicrophoneID.isEmpty
                    )
                }
                Divider()
                ForEach(vm.availableMicrophones, id: \.uniqueID) { device in
                    Button {
                        vm.selectedMicrophoneID = device.uniqueID
                    } label: {
                        CheckmarkLabel(
                            title: device.localizedName,
                            isSelected: vm.selectedMicrophoneID == device.uniqueID
                        )
                    }
                }
            }
        }
        .disabled(viewModel == nil || viewModel!.isSessionActive)
    }

    // MARK: - Bindings and Computed Helpers

    private var alwaysOnTopBinding: Binding<Bool> {
        Binding(
            get: { viewModel?.isAlwaysOnTop ?? false },
            set: { viewModel?.isAlwaysOnTop = $0 }
        )
    }

    private var subtitleModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel?.displayMode == .subtitle },
            set: { _ in viewModel?.toggleDisplayMode() }
        )
    }

    private var subtitleModeLabel: String {
        viewModel?.displayMode == .subtitle ? "Normal Mode" : "Subtitle Mode"
    }

    private var subtitleButtonDisabled: Bool {
        guard let vm = viewModel else { return true }
        if vm.displayMode == .subtitle { return false }
        if !vm.isSessionActive { return true }
        return vm.targetCount > 1
    }

    private func copyToClipboard(_ string: String?) {
        guard let string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
