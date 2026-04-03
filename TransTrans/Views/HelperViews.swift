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

// MARK: - Checkmark Menu Item Label

/// A menu button label that shows a checkmark when selected.
struct CheckmarkLabel: View {
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
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Pasteboard Helper

/// Copies a string to the system clipboard.
func copyToClipboard(_ string: String?) {
    guard let string else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

// MARK: - Audio Level Color

/// Returns a color for the given normalized audio level (0.0–1.0).
/// Shared by `AudioWaveformView` and `AudioLevelPopoverView`.
func audioLevelColor(level: Float, isActive: Bool) -> Color {
    if !isActive { return .secondary }
    if level > 0.92 { return .red }
    if level > 0.78 { return .orange }
    if level > 0.2 { return .green }
    return .gray   // below silence threshold (~-40 dB)
}

// MARK: - Audio Waveform Visualization

struct AudioWaveformView: View {
    var levels: [Float]
    var isActive: Bool

    private let barSpacing: CGFloat = 1

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(levels.indices, id: \.self) { index in
                let level = CGFloat(levels[index])
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(audioLevelColor(level: levels[index], isActive: isActive))
                    .frame(width: 1, height: max(2, level * 28))
            }
        }
        .opacity(isActive ? 1.0 : 0.3)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}
