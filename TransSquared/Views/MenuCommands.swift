import SwiftUI
import AVFoundation
import Speech
import os

private let logger = Logger.app("MenuCommands")

// MARK: - App Menu Commands

struct AppMenuCommands: Commands {
    @FocusedValue(SessionViewModel.self) private var viewModel
    #if DEBUG
    @MainActor static let debugWindowController = DebugWindowController()
    #endif

    var body: some Commands {
        // App menu: Settings
        CommandGroup(replacing: .appSettings) {
            Button("Settings...") {
                viewModel?.showSettings = true
            }
            .keyboardShortcut(",")
            .disabled(viewModel == nil)
        }

        // File menu: Transcribe audio file + Save transcript
        CommandGroup(replacing: .saveItem) {
            Button("Transcribe Audio File...") {
                viewModel?.showFileImporter = true
            }
            .keyboardShortcut("o")
            .disabled(transcribeFileDisabled)

            Divider()

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

            Divider()

            if let vm = viewModel {
                SubtitleExportMenuItems(viewModel: vm)
            }

            Divider()

            Button("Save Audio Recording (.m4a)...") {
                viewModel?.exportAudioRecording()
            }
            .disabled(viewModel?.hasRecording != true)
        }

        // Edit menu: Copy and Clear
        CommandGroup(after: .pasteboard) {
            Section {
                Button("Copy All (Original)") {
                    NSPasteboard.general.copyString(viewModel?.copyAllOriginal())
                }
                .disabled(viewModel?.hasTranscriptContent != true)

                Button("Copy All (Translation)") {
                    NSPasteboard.general.copyString(viewModel?.copyAllTranslation())
                }
                .disabled(viewModel?.hasTranscriptContent != true)

                Button("Copy All (Interleaved)") {
                    NSPasteboard.general.copyString(viewModel?.copyAllInterleaved())
                }
                .disabled(viewModel?.hasTranscriptContent != true)
            }

            Section {
                Button("Clear History") {
                    viewModel?.clearHistory()
                }
                .disabled(clearHistoryDisabled)
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
                    .disabled(viewModel?.isSubtitleButtonDisabled ?? true)
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
            .disabled(viewModel?.isSessionActive ?? true)

            Divider()

            Button("Add Target Language") {
                viewModel?.addTargetLanguage()
            }
            .disabled(addTargetDisabled)

            Button("Remove Target Language") {
                viewModel?.removeTargetLanguage()
            }
            .disabled(removeTargetDisabled)

            Divider()

            // Microphone submenu
            microphoneMenu
        }

        // Help menu
        CommandGroup(replacing: .help) {
            Link("Trans² Support",
                 destination: URL(staticString: "https://github.com/kcrt/TransSquared"))
            Link("Report an Issue (GitHub)",
                 destination: URL(staticString: "https://github.com/kcrt/TransSquared/issues"))
        }

        #if DEBUG
        CommandMenu("DEBUG") {
            Button("Debug Inspector") {
                if let vm = viewModel {
                    AppMenuCommands.debugWindowController.toggle(viewModel: vm)
                }
            }
            .disabled(viewModel == nil)

            Divider()

            Button("Release All Speech Models (except ja/en)") {
                Task {
                    let keepLanguageCodes: Set<String> = ["ja", "en"]
                    let reserved = await AssetInventory.reservedLocales
                    logger.debug("Releasing speech models (reserved: \(reserved.count))...")
                    var releasedCount = 0
                    for locale in reserved {
                        let langCode = locale.language.languageCode?.identifier ?? ""
                        if !keepLanguageCodes.contains(langCode) {
                            let released = await AssetInventory.release(reservedLocale: locale)
                            logger.debug("  \(locale.identifier): \(released ? "released" : "not reserved")")
                            if released { releasedCount += 1 }
                        } else {
                            logger.debug("  \(locale.identifier): kept")
                        }
                    }
                    logger.debug("Released \(releasedCount) locale(s)")
                    // Reload supported locales and install status
                    if let vm = viewModel {
                        await vm.loadSupportedLocales()
                        logger.debug("Reloaded supported locales (installed: \(vm.installedSourceLocaleIdentifiers.count))")
                    }
                }
            }

            Button("Log Reserved Locales") {
                Task {
                    let reserved = await AssetInventory.reservedLocales
                    let max = AssetInventory.maximumReservedLocales
                    logger.debug("Reserved locales (\(reserved.count)/\(max)):")
                    if reserved.isEmpty {
                        logger.debug("  (none)")
                    } else {
                        for locale in reserved {
                            let status = await AssetInventory.status(forModules: [
                                SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
                            ])
                            logger.debug("  - \(locale.identifier): \(String(describing: status))")
                        }
                    }
                }
            }
        }
        #endif
    }

    // MARK: - Submenus

    @ViewBuilder
    private var sourceLanguageMenu: some View {
        Menu("Source Language") {
            if let vm = viewModel {
                SourceLanguageMenuContent(viewModel: vm)
            }
        }
        .disabled(viewModel?.isSessionActive ?? true)
    }

    @ViewBuilder
    private var targetLanguageMenus: some View {
        if let vm = viewModel {
            ForEach(0..<vm.targetCount, id: \.self) { slot in
                Menu(vm.targetCount == 1
                    ? "Target Language"
                    : "Target Language \(slot + 1)"
                ) {
                    TargetLanguageMenuContent(viewModel: vm, slot: slot)
                }
                .disabled(vm.isSessionActive)
            }
        }
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        Menu("Microphone") {
            if let vm = viewModel {
                MicrophoneMenuContent(viewModel: vm)
            }
        }
        .disabled(viewModel?.isSessionActive ?? true)
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
        viewModel?.displayMode == .subtitle ? String(localized: "Normal Mode") : String(localized: "Subtitle Mode")
    }

    private var clearHistoryDisabled: Bool {
        guard let vm = viewModel else { return true }
        return vm.isSessionActive || !vm.hasTranscriptContent
    }

    private var addTargetDisabled: Bool {
        guard let vm = viewModel else { return true }
        return vm.isSessionActive || vm.targetCount >= SessionViewModel.maxTargetCount
    }

    private var removeTargetDisabled: Bool {
        guard let vm = viewModel else { return true }
        return vm.isSessionActive || vm.targetCount <= 1
    }

    private var transcribeFileDisabled: Bool {
        guard let vm = viewModel else { return true }
        return vm.isSessionActive || vm.isTranscribingFile
    }

}
