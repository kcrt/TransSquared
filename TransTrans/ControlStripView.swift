import SwiftUI
import AVFoundation
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
                        if viewModel.selectedMicrophoneID.isEmpty {
                            Label("System Default", systemImage: "checkmark")
                        } else {
                            Text("System Default")
                        }
                    }
                    Divider()
                    ForEach(viewModel.availableMicrophones, id: \.uniqueID) { device in
                        Button {
                            viewModel.selectedMicrophoneID = device.uniqueID
                        } label: {
                            if viewModel.selectedMicrophoneID == device.uniqueID {
                                Label(device.localizedName, systemImage: "checkmark")
                            } else {
                                Text(device.localizedName)
                            }
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
                            if viewModel.sourceLocaleIdentifier == locale.identifier {
                                Label(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier, systemImage: "checkmark")
                            } else {
                                Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            }
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
                            if viewModel.targetLanguageIdentifier == language.minimalIdentifier {
                                Label(displayName(for: language), systemImage: "checkmark")
                            } else {
                                Text(displayName(for: language))
                            }
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

