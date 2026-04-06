import SwiftUI
import AVFoundation
import os

private let logger = Logger.app("ContentView")

// MARK: - Toolbar

extension ContentView {

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        // Group 1: Waveform (standalone) + Rec/Stop split button + Mic
        ToolbarItemGroup {
            // RMS Monitor — always visible; click to open level monitor popover
            Button {
                viewModel.showAudioPopover.toggle()
            } label: {
                AudioWaveformView(levels: viewModel.audioLevelMonitor.levels, isActive: viewModel.isSessionActive)
                    .frame(width: 60, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: Bindable(viewModel).showAudioPopover) {
                AudioLevelPopoverView(
                    audioLevels: viewModel.audioLevelMonitor.levels,
                    isActive: viewModel.isSessionActive,
                    silenceThreshold: SessionViewModel.silenceThreshold,
                    inputDeviceName: (viewModel.selectedMicrophone ?? AVCaptureDevice.default(for: .audio))?.localizedName,
                    volumeService: MicrophoneVolumeService(device: viewModel.selectedMicrophone)
                )
            }
            .help("Audio Level Monitor")

            // Session toggle: start/stop recording + transcription
            Button {
                viewModel.toggleSession()
            } label: {
                if isSourceLanguageDownloading {
                    Image(systemName: "arrow.down.circle")
                        .symbolEffect(.wiggle.byLayer, options: .repeat(.periodic(delay: 0.0)))
                        .accessibilityLabel("Downloading")
                } else {
                    Image(nsImage: Self.redSymbol(named: sessionButtonIcon))
                        .symbolEffect(.pulse, options: .repeating, isActive: shouldBlinkRecordIcon)
                        .accessibilityLabel(viewModel.isSessionActive ? "Stop" : "Start")
                }
            }
            .help(sessionButtonHelp)

            Menu {
                Button {
                    viewModel.selectedMicrophoneID = ""
                } label: {
                    CheckmarkLabel(title: String(localized: "System Default"), isSelected: viewModel.selectedMicrophoneID.isEmpty)
                }
                if viewModel.selectedMicrophoneID.isEmpty,
                   let defaultName = AVCaptureDevice.default(for: .audio)?.localizedName {
                    Text("  ↳ \(defaultName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    viewModel.displayMode == .subtitle ? String(localized: "Normal Mode") : String(localized: "Subtitle Mode"),
                    systemImage: viewModel.displayMode == .subtitle ? "captions.bubble.fill" : "captions.bubble"
                )
            }
            .disabled(viewModel.isSubtitleButtonDisabled)
            .help(subtitleButtonHelp)

            Button {
                viewModel.isAlwaysOnTop.toggle()
            } label: {
                Label("Always on Top", systemImage: "pin.fill")
                    .foregroundStyle(viewModel.isAlwaysOnTop ? .orange : .secondary)
            }
            .help("Always on Top (⌘T)")
        }

        // Group 4: Language controls — source
        ToolbarItemGroup {
            Menu {
                SourceLanguageMenuContent(viewModel: viewModel)
            } label: {
                HStack(spacing: 4) {
                    Text(sourceLanguageLabel)
                        .fontWeight(.medium)
                    if viewModel.downloadingSourceLocaleIdentifiers.contains(viewModel.sourceLocaleIdentifier) {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(viewModel.isSessionActive)
            .help("Source Language")
        }

        // Swap / arrow
        if viewModel.targetCount == 1 {
            ToolbarItem {
                Button {
                    viewModel.swapLanguages()
                } label: {
                    Label("Swap", systemImage: "arrow.left.arrow.right")
                }
                .disabled(viewModel.isSessionActive)
                .help("Swap Languages (⌘⇧S)")
            }
        } else {
            ToolbarItem {
                Text("→")
                    .foregroundStyle(.secondary)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        // Language controls — targets
        ToolbarItemGroup {
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
        let langId = slot < viewModel.targetLanguageIdentifiers.count
            ? viewModel.targetLanguageIdentifiers[slot] : "?"
        Menu {
            TargetLanguageMenuContent(viewModel: viewModel, slot: slot)
        } label: {
            Text(langId.uppercased())
                .fontWeight(.medium)
        }
        .disabled(viewModel.isSessionActive)
        .help("Target Language \(slot + 1)")
    }

    // MARK: - Session Button Helpers

    private var sessionButtonIcon: String {
        viewModel.isSessionActive ? "stop.fill" : "circle.fill"
    }

    private var isSourceLanguageDownloading: Bool {
        viewModel.downloadingSourceLocaleIdentifiers.contains(viewModel.sourceLocaleIdentifier)
    }

    private var shouldBlinkRecordIcon: Bool {
        viewModel.isSessionActive
    }

    private var sessionButtonHelp: String {
        if isSourceLanguageDownloading {
            return String(localized: "Downloading speech model… Click to cancel.")
        }
        return viewModel.isSessionActive ? "Stop (⌘R)" : "Start (⌘R)"
    }

    /// Creates an SF Symbol NSImage tinted red with `isTemplate = false`
    /// so that macOS toolbar styling does not override the color.
    private static func redSymbol(named name: String) -> NSImage {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let colored = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) else {
            return NSImage()
        }
        colored.isTemplate = false
        return colored
    }

    // MARK: - Toolbar Helpers

    var sourceLanguageLabel: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return locale.language.minimalIdentifier.uppercased()
    }

    var microphoneHelpText: String {
        if viewModel.selectedMicrophoneID.isEmpty {
            return String(localized: "Microphone: System Default")
        }
        if let device = viewModel.selectedMicrophone {
            return String(localized: "Microphone: \(device.localizedName)")
        }
        return String(localized: "Microphone")
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
