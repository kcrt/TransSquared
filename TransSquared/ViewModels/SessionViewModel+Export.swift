import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger.app("Export")

// MARK: - Save / Export

extension SessionViewModel {

    enum SaveContentType {
        case original
        case translation
        case both
    }

    /// Prepares transcript content for export via SwiftUI's `.fileExporter`.
    /// The actual file-save dialog is presented by the View layer.
    func saveTranscript(contentType: SaveContentType) {
        let content: String
        switch contentType {
        case .original:
            content = copyAllOriginal()
        case .translation:
            content = copyAllTranslation()
        case .both:
            content = copyAllInterleaved()
        }

        guard !content.isEmpty else { return }

        exportContent = content
        exportDefaultFilename = defaultFileName(for: contentType)
        exportContentTypes = [.plainText]
        isExporterPresented = true
    }

    private func defaultFileName(for contentType: SaveContentType) -> String {
        let suffix: String
        switch contentType {
        case .original: suffix = "original"
        case .translation: suffix = "translation"
        case .both: suffix = "interleaved"
        }
        return "TransSquared_\(Self.fileTimestamp())_\(suffix).txt"
    }

    // MARK: - Copy / Export Helpers

    func clearHistory() {
        resetTranscriptState()
        sessionStartDate = nil
        cleanupRecording()
    }

    /// Presents a save panel for exporting the recorded audio file.
    func exportAudioRecording() {
        guard let sourceURL = currentRecordingURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = defaultAudioFileName()
        panel.begin { [weak self, sourceURL] response in
            guard response == .OK, let destURL = panel.url else { return }
            // Offload file I/O to avoid blocking the main thread for large files.
            Task.detached {
                do {
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destURL)
                    logger.info("Audio recording exported to \(destURL.path)")
                } catch {
                    logger.error("Failed to export audio: \(error.localizedDescription)")
                    await MainActor.run { [weak self] in
                        self?.errorMessage = "Failed to export audio: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func defaultAudioFileName() -> String {
        "TransSquared_\(Self.fileTimestamp())_recording.m4a"
    }

    func copyAllOriginal() -> String {
        entries.filter { !$0.isSeparator && !$0.source.text.isEmpty }
            .map(\.source.text)
            .joined(separator: "\n")
    }

    func copyAllTranslation() -> String {
        let slotCount = min(targetCount, translationSlots.count)
        var result: [String] = []
        for slot in 0..<slotCount {
            if slotCount > 1 {
                let langId = slot < targetLanguageIdentifiers.count
                    ? targetLanguageIdentifiers[slot].uppercased() : "?"
                result.append("[\(langId)]")
            }
            let lines = entries.filter { !$0.isSeparator }
                .compactMap { $0.translations[slot] }
                .filter { !$0.isPartial }
                .map(\.text)
            result.append(contentsOf: lines)
            if slotCount > 1 { result.append("") }
        }
        return result.joined(separator: "\n")
    }

    func copyAllInterleaved() -> String {
        var result: [String] = []
        let slotCount = min(targetCount, translationSlots.count)

        for entry in entries where !entry.isSeparator && !entry.source.text.isEmpty {
            result.append(entry.source.text)
            // Translation for each slot
            for slot in 0..<slotCount {
                if let trans = entry.translations[slot], !trans.isPartial {
                    result.append(trans.text)
                }
            }
            result.append("")
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Subtitle Export

    enum SubtitleFormat {
        case srt
        case vtt

        var fileExtension: String {
            switch self {
            case .srt: return "srt"
            case .vtt: return "vtt"
            }
        }

        var contentType: UTType {
            switch self {
            case .srt: return UTType(filenameExtension: "srt") ?? .plainText
            case .vtt: return UTType(filenameExtension: "vtt") ?? .plainText
            }
        }
    }

    /// Prepares subtitle content for export via SwiftUI's `.fileExporter`.
    /// The actual file-save dialog is presented by the View layer.
    func exportSubtitle(format: SubtitleFormat, contentType: SaveContentType) {
        let content = generateSubtitleContent(format: format, contentType: contentType)
        guard !content.isEmpty else { return }

        exportContent = content
        exportDefaultFilename = defaultSubtitleFileName(format: format, contentType: contentType)
        exportContentTypes = [format.contentType]
        isExporterPresented = true
    }

    private func defaultSubtitleFileName(format: SubtitleFormat, contentType: SaveContentType) -> String {
        let suffix: String
        switch contentType {
        case .original: suffix = "original"
        case .translation: suffix = "translation"
        case .both: suffix = "bilingual"
        }
        return "TransSquared_\(Self.fileTimestamp())_\(suffix).\(format.fileExtension)"
    }

    // MARK: - Subtitle Generation

    private func generateSubtitleContent(format: SubtitleFormat, contentType: SaveContentType) -> String {
        let cues = subtitleCues(contentType: contentType)
        guard !cues.isEmpty else { return "" }

        let msSeparator: String = format == .srt ? "," : "."
        var result: [String] = format == .vtt ? ["WEBVTT", ""] : []
        for (index, cue) in cues.enumerated() {
            result.append("\(index + 1)")
            result.append("\(formatSubtitleTimestamp(cue.startTime, millisecondSeparator: msSeparator)) --> \(formatSubtitleTimestamp(cue.endTime, millisecondSeparator: msSeparator))")
            result.append(cue.text)
            result.append("")
        }
        return result.joined(separator: "\n")
    }

    // MARK: - Filename Helpers

    /// Shared formatter for `yyyyMMdd_HHmmss` export filename timestamps.
    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    /// Generates a `yyyyMMdd_HHmmss` timestamp for export filenames.
    private static func fileTimestamp() -> String {
        fileTimestampFormatter.string(from: Date())
    }

    // MARK: - Subtitle Helpers

    private struct SubtitleCue {
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    /// Builds subtitle cues from transcript entries that have timing data.
    private func subtitleCues(contentType: SaveContentType) -> [SubtitleCue] {
        let slotCount = min(targetCount, translationSlots.count)

        return entries.compactMap { entry -> SubtitleCue? in
            guard !entry.isSeparator,
                  !entry.source.text.isEmpty,
                  let startTime = entry.elapsedTime else { return nil }

            let endTime = startTime + (entry.duration ?? 3.0)

            let text: String
            switch contentType {
            case .original:
                text = entry.source.text
            case .translation:
                let translationLines = (0..<slotCount).compactMap { slot -> String? in
                    guard let trans = entry.translations[slot], !trans.isPartial else { return nil }
                    return trans.text
                }
                guard !translationLines.isEmpty else { return nil }
                text = translationLines.joined(separator: "\n")
            case .both:
                var lines = [entry.source.text]
                for slot in 0..<slotCount {
                    if let trans = entry.translations[slot], !trans.isPartial {
                        lines.append(trans.text)
                    }
                }
                text = lines.joined(separator: "\n")
            }

            return SubtitleCue(startTime: startTime, endTime: endTime, text: text)
        }
    }

    /// Formats a time interval as a subtitle timestamp with the given millisecond separator.
    /// SRT uses `,` and VTT uses `.` as the separator.
    private func formatSubtitleTimestamp(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d\(millisecondSeparator)%03d", h, m, s, ms)
    }
}
