import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Save Transcript Menu Items (shared between context menu and toolbar)

/// Reusable menu content for save transcript actions.
struct SaveTranscriptMenuItems: View {
    let viewModel: SessionViewModel

    var body: some View {
        Button("Original") {
            viewModel.saveTranscript(contentType: .original)
        }
        Button("Translation") {
            viewModel.saveTranscript(contentType: .translation)
        }
        Button("Both (Interleaved)") {
            viewModel.saveTranscript(contentType: .both)
        }
        Divider()
        Menu("Subtitle (.srt)") {
            Button("Original") {
                viewModel.exportSubtitle(format: .srt, contentType: .original)
            }
            Button("Translation") {
                viewModel.exportSubtitle(format: .srt, contentType: .translation)
            }
            Button("Both") {
                viewModel.exportSubtitle(format: .srt, contentType: .both)
            }
        }
        Menu("Subtitle (.vtt)") {
            Button("Original") {
                viewModel.exportSubtitle(format: .vtt, contentType: .original)
            }
            Button("Translation") {
                viewModel.exportSubtitle(format: .vtt, contentType: .translation)
            }
            Button("Both") {
                viewModel.exportSubtitle(format: .vtt, contentType: .both)
            }
        }
        if viewModel.hasRecording {
            Divider()
            Button("Audio Recording (.m4a)") {
                viewModel.exportAudioRecording()
            }
        }
    }
}

// MARK: - Shared Language Menu Content

/// Shared source language menu items used by both the toolbar and menu bar.
struct SourceLanguageMenuContent: View {
    var viewModel: SessionViewModel

    var body: some View {
        ForEach(viewModel.supportedSourceLocales, id: \.identifier) { locale in
            Button {
                viewModel.sourceLocaleIdentifier = locale.identifier
                viewModel.downloadSpeechAssetsIfNeeded(for: locale)
                Task { await viewModel.updateTargetLanguages() }
            } label: {
                CheckmarkLabel(
                    title: locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier,
                    isSelected: viewModel.sourceLocaleIdentifier == locale.identifier,
                    isDownloaded: viewModel.installedSourceLocaleIdentifiers.contains(locale.identifier),
                    isDownloading: viewModel.downloadingSourceLocaleIdentifiers.contains(locale.identifier)
                )
            }
        }
    }
}

/// Shared target language menu items for a single slot.
struct TargetLanguageMenuContent: View {
    var viewModel: SessionViewModel
    var slot: Int

    var body: some View {
        ForEach(viewModel.supportedTargetLanguages, id: \.minimalIdentifier) { language in
            Button {
                viewModel.targetLanguageIdentifiers[slot] = language.minimalIdentifier
                viewModel.prepareTranslationModelIfNeeded(for: language.minimalIdentifier)
            } label: {
                CheckmarkLabel(
                    title: Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
                        ?? language.minimalIdentifier,
                    isSelected: viewModel.targetLanguageIdentifiers[slot] == language.minimalIdentifier,
                    isDownloaded: viewModel.targetLanguageDownloadStatus[language.minimalIdentifier] == true
                )
            }
        }
    }
}

// MARK: - Checkmark Menu Item Label

/// A menu button label that shows a checkmark when selected, a cloud icon when not downloaded,
/// or a progress indicator when downloading.
struct CheckmarkLabel: View {
    let title: String
    let isSelected: Bool
    var isDownloaded: Bool = true
    var isDownloading: Bool = false

    var body: some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else if isDownloading {
            Label(title, systemImage: "arrow.down.circle")
        } else if !isDownloaded {
            Label(title, systemImage: "icloud.and.arrow.down")
        } else {
            Text(title)
        }
    }
}

// MARK: - File Transcription Progress Sheet

/// A small sheet shown while an audio file is being transcribed.
struct FileTranscriptionProgressView: View {
    var viewModel: SessionViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Transcribing Audio File…")
                .font(.headline)

            // Transcription progress
            VStack(alignment: .leading, spacing: 4) {
                Text(transcriptionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: viewModel.fileTranscriptionProgress)
                    .progressViewStyle(.linear)
            }

            // Translation progress per slot
            ForEach(0..<viewModel.targetCount, id: \.self) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(translationLabel(slot: slot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if viewModel.fileTranscriptionProgress >= 1.0 {
                        ProgressView(value: viewModel.fileTranslationProgress(forSlot: slot))
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
            }

            // Show the latest partial text as real-time feedback.
            if let lastPartial = viewModel.sourceLines.last, lastPartial.isPartial {
                Text(lastPartial.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Cancel") {
                viewModel.cancelFileTranscription()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 400)
    }

    // MARK: - Formatted Labels

    private var transcriptionLabel: String {
        let progress = viewModel.fileTranscriptionProgress
        let duration = viewModel.fileAudioDuration
        let pct = Int(progress * 100)
        guard duration > 0 else {
            return String(localized: "Transcription")
        }
        let elapsed = formatTime(progress * duration)
        let total = formatTime(duration)
        return String(localized: "Transcription") + " — \(pct)% (\(elapsed) / \(total))"
    }

    private func translationLabel(slot: Int) -> String {
        let langId = viewModel.targetLanguageIdentifiers[slot]
        let langName = Locale.current.localizedString(forIdentifier: langId) ?? langId
        let base = String(localized: "Translation") + " (\(langName))"

        guard viewModel.fileTranscriptionProgress >= 1.0, viewModel.segmentIndex > 0 else {
            return base
        }
        let total = viewModel.segmentIndex
        let progress = viewModel.fileTranslationProgress(forSlot: slot)
        let completed = Int(Double(total) * progress)
        let pct = Int(progress * 100)
        return base + " — \(pct)% (\(completed)/\(total))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        seconds.formattedMSS
    }
}

// MARK: - Pasteboard Helper

extension NSPasteboard {
    /// Replaces the pasteboard contents with the given string.
    func copyString(_ string: String?) {
        guard let string else { return }
        clearContents()
        setString(string, forType: .string)
    }
}

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barSpacing: CGFloat = 1

    /// Returns a color for the given normalized audio level (0.0–1.0).
    /// Shared by `AudioWaveformView` and `AudioLevelPopoverView`.
    static func levelColor(_ level: Float, isActive: Bool) -> Color {
        if !isActive { return .secondary }
        if level > 0.92 { return .red }
        if level > 0.78 { return .orange }
        if level > 0.2 { return .green }
        return .gray   // below silence threshold (~-40 dB)
    }

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(levels.indices, id: \.self) { index in
                let level = CGFloat(levels[index])
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Self.levelColor(levels[index], isActive: isActive))
                    .frame(width: 1, height: max(2, level * 28))
            }
        }
        .opacity(isActive ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityElement()
        .accessibilityLabel(isActive ? String(localized: "Audio waveform, active") : String(localized: "Audio waveform, inactive"))
    }
}
