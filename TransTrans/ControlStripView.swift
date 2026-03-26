import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "com.transtrans", category: "ControlStrip")

struct ControlStripView: View {
    @Bindable var viewModel: SessionViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            // Column 1 (left): font size, spacer, network, pin
            VStack(spacing: 8) {
                Button {
                    viewModel.increaseFontSize()
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Increase Font Size (⌘+)")

                Button {
                    viewModel.decreaseFontSize()
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Decrease Font Size (⌘-)")

                Spacer()

                Menu {
                    Button("Original") {
                        viewModel.saveTranscript(contentType: .original)
                    }
                    Button("Translation") {
                        viewModel.saveTranscript(contentType: .translation)
                    }
                    Button("Both (Interleaved)") {
                        viewModel.saveTranscript(contentType: .both)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(viewModel.sourceLines.isEmpty && viewModel.targetLines.isEmpty)
                .help("Save Transcript (⌘S)")

                Button {
                    viewModel.clearHistory()
                } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSessionActive || (viewModel.sourceLines.isEmpty && viewModel.targetLines.isEmpty))
                .help("Clear History")

                // Toggle: Single (dual) ↔ Multi pane
                Button {
                    viewModel.displayMode = viewModel.displayMode == .multi ? .dual : .multi
                } label: {
                    Image(systemName: "rectangle.grid.1x3")
                        .font(.title3)
                        .foregroundStyle(viewModel.displayMode == .multi ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSessionActive)
                .help(viewModel.displayMode == .multi ? "Single Pane (⌘M)" : "Multi Pane (⌘M)")

                // Toggle: Single (dual) ↔ Subtitle
                Button {
                    if viewModel.displayMode == .subtitle {
                        viewModel.displayMode = .dual
                    } else if viewModel.displayMode == .dual {
                        viewModel.displayMode = .subtitle
                    }
                } label: {
                    Image(systemName: viewModel.displayMode == .subtitle ? "captions.bubble.fill" : "captions.bubble")
                        .font(.title3)
                        .foregroundStyle(viewModel.displayMode == .subtitle ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.displayMode == .multi || (!viewModel.isSessionActive && viewModel.displayMode != .subtitle))
                .help(viewModel.displayMode == .subtitle ? "Single Pane (⌘D)" : "Subtitle Mode (⌘D)")

                Button {
                    viewModel.showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    viewModel.isAlwaysOnTop.toggle()
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.title3)
                        .foregroundStyle(viewModel.isAlwaysOnTop ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Always on Top (⌘T)")
            }
            .frame(width: 28)

            // Column 2 (right): waveform, rec/stop, mic, languages
            VStack(spacing: 8) {
                AudioWaveformView(levels: viewModel.audioLevels, isActive: viewModel.isSessionActive)
                    .frame(width: 28, height: 28)

                Button {
                    viewModel.toggleSession()
                } label: {
                    Image(systemName: viewModel.isSessionActive ? "stop.fill" : "circle.fill")
                        .font(.title2)
                        .foregroundStyle(viewModel.isSessionActive ? .red : .pink)
                }
                .buttonStyle(.plain)
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
                    Image(systemName: "mic.fill")
                        .font(.title3)
                        .foregroundColor(viewModel.selectedMicrophoneID.isEmpty ? .secondary : .accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(viewModel.isSessionActive)
                .help(microphoneHelpText)
                .onAppear {
                    viewModel.refreshMicrophones()
                }

                Divider()

                // Source language (FROM)
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
                        .font(.caption)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(viewModel.isSessionActive)
                .help("Source Language")

                if viewModel.displayMode == .multi {
                    // Multi-pane: multiple target language pickers
                    Divider()

                    ForEach(0..<viewModel.multiTargetCount, id: \.self) { slot in
                        multiTargetPicker(slot: slot)
                    }

                    // Add/remove target buttons
                    HStack(spacing: 4) {
                        if viewModel.multiTargetCount < SessionViewModel.maxMultiTargetCount {
                            Button {
                                viewModel.addMultiTarget()
                            } label: {
                                Image(systemName: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSessionActive)
                            .help("Add Target Language")
                        }
                        if viewModel.multiTargetCount > 2 {
                            Button {
                                viewModel.removeMultiTarget()
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSessionActive)
                            .help("Remove Target Language")
                        }
                    }
                } else {
                    // Dual-pane: swap button + single target picker

                    // Swap languages
                    Button {
                        viewModel.swapLanguages()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSessionActive)
                    .help("Swap Languages (⌘⇧S)")

                    // Target language (TO)
                    Menu {
                        ForEach(viewModel.supportedTargetLanguages, id: \.minimalIdentifier) { language in
                            Button {
                                logger.info("Target language selected: '\(language.minimalIdentifier)' (was '\(viewModel.targetLanguageIdentifier)')")
                                viewModel.targetLanguageIdentifier = language.minimalIdentifier
                            } label: {
                                CheckmarkLabel(
                                    title: displayName(for: language),
                                    isSelected: viewModel.targetLanguageIdentifier == language.minimalIdentifier
                                )
                            }
                        }
                    } label: {
                        Text(targetLanguageLabel)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(viewModel.isSessionActive)
                    .help("Target Language")
                }
            }
            .frame(width: 36)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private var sourceLanguageLabel: String {
        let locale = Locale(identifier: viewModel.sourceLocaleIdentifier)
        return locale.language.languageCode?.identifier.uppercased() ?? viewModel.sourceLocaleIdentifier
    }

    private var targetLanguageLabel: String {
        viewModel.targetLanguageIdentifier.uppercased()
    }

    private func displayName(for language: Locale.Language) -> String {
        let identifier = language.minimalIdentifier
        // Use forIdentifier to distinguish scripts (e.g. "Chinese, Simplified" vs "Chinese, Traditional")
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

    @ViewBuilder
    private func multiTargetPicker(slot: Int) -> some View {
        Menu {
            ForEach(viewModel.supportedTargetLanguages, id: \.minimalIdentifier) { language in
                Button {
                    logger.info("Multi target \(slot) selected: '\(language.minimalIdentifier)' (was '\(viewModel.multiTargetLanguageIdentifiers[slot])')")
                    viewModel.multiTargetLanguageIdentifiers[slot] = language.minimalIdentifier
                } label: {
                    CheckmarkLabel(
                        title: displayName(for: language),
                        isSelected: viewModel.multiTargetLanguageIdentifiers[slot] == language.minimalIdentifier
                    )
                }
            }
        } label: {
            Text(viewModel.multiTargetLanguageIdentifiers[slot].uppercased())
                .font(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(viewModel.isSessionActive)
        .help("Target Language \(slot + 1)")
    }
}
// MARK: - Checkmark Menu Item Label

/// A menu button label that shows a checkmark when selected.
private struct CheckmarkLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barCount = 20
    private let barSpacing: CGFloat = 1

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let level = index < levels.count ? CGFloat(levels[index]) : 0
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(barColor(level: level))
                    .frame(width: 1, height: max(2, level * 28))
            }
        }
        .opacity(isActive ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.08), value: levels)
    }

    private func barColor(level: CGFloat) -> Color {
        if !isActive { return .secondary }
        if level > 0.7 { return .red }
        if level > 0.4 { return .orange }
        return .green
    }
}

