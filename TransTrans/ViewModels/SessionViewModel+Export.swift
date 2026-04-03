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
        isExporterPresented = true
    }

    private func defaultFileName(for contentType: SaveContentType) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix: String
        switch contentType {
        case .original: suffix = "original"
        case .translation: suffix = "translation"
        case .both: suffix = "interleaved"
        }
        return "TransTrans_\(timestamp)_\(suffix).txt"
    }

    // MARK: - Copy / Export Helpers

    func clearHistory() {
        entries = []
        for slot in 0..<translationSlots.count {
            translationSlots[slot].queue = []
        }
        accumulatedElapsedTime = 0
        sessionStartDate = nil
        cleanupRecording()
    }

    /// Presents a save panel for exporting the recorded audio file.
    func exportAudioRecording() {
        guard let sourceURL = currentRecordingURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = defaultAudioFileName()
        panel.begin { [sourceURL] response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                logger.info("Audio recording exported to \(destURL.path)")
            } catch {
                logger.error("Failed to export audio: \(error.localizedDescription)")
            }
        }
    }

    private func defaultAudioFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        return "TransTrans_\(timestamp)_recording.m4a"
    }

    func copyAllOriginal() -> String {
        entries.filter { !$0.isSeparator && !$0.source.text.isEmpty }
            .map(\.source.text)
            .joined(separator: "\n")
    }

    func copyAllTranslation() -> String {
        let slotCount = min(targetCount, translationSlots.count)
        if slotCount > 1 {
            var result: [String] = []
            for slot in 0..<slotCount {
                let langId = slot < targetLanguageIdentifiers.count
                    ? targetLanguageIdentifiers[slot].uppercased() : "?"
                result.append("[\(langId)]")
                let lines = entries.filter { !$0.isSeparator }
                    .compactMap { $0.translations[slot] }
                    .filter { !$0.isPartial }
                    .map(\.text)
                result.append(contentsOf: lines)
                result.append("")
            }
            return result.joined(separator: "\n")
        }
        return entries.filter { !$0.isSeparator }
            .compactMap { $0.translations[0] }
            .filter { !$0.isPartial }
            .map(\.text)
            .joined(separator: "\n")
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

    /// Presents a save panel for exporting a subtitle file.
    func exportSubtitle(format: SubtitleFormat, contentType: SaveContentType) {
        let content: String
        switch format {
        case .srt:
            content = generateSRT(contentType: contentType)
        case .vtt:
            content = generateVTT(contentType: contentType)
        }

        guard !content.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = defaultSubtitleFileName(format: format, contentType: contentType)
        panel.begin { response in
            guard response == .OK, let destURL = panel.url else { return }
            do {
                try content.write(to: destURL, atomically: true, encoding: .utf8)
                logger.info("Subtitle exported to \(destURL.path)")
            } catch {
                logger.error("Failed to export subtitle: \(error.localizedDescription)")
            }
        }
    }

    private func defaultSubtitleFileName(format: SubtitleFormat, contentType: SaveContentType) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix: String
        switch contentType {
        case .original: suffix = "original"
        case .translation: suffix = "translation"
        case .both: suffix = "bilingual"
        }
        return "TransTrans_\(timestamp)_\(suffix).\(format.fileExtension)"
    }

    // MARK: - SRT Generation

    private func generateSRT(contentType: SaveContentType) -> String {
        let cues = subtitleCues(contentType: contentType)
        guard !cues.isEmpty else { return "" }

        var result: [String] = []
        for (index, cue) in cues.enumerated() {
            result.append("\(index + 1)")
            result.append("\(formatSRTTimestamp(cue.startTime)) --> \(formatSRTTimestamp(cue.endTime))")
            result.append(cue.text)
            result.append("")
        }
        return result.joined(separator: "\n")
    }

    // MARK: - VTT Generation

    private func generateVTT(contentType: SaveContentType) -> String {
        let cues = subtitleCues(contentType: contentType)
        guard !cues.isEmpty else { return "" }

        var result: [String] = ["WEBVTT", ""]
        for (index, cue) in cues.enumerated() {
            result.append("\(index + 1)")
            result.append("\(formatVTTTimestamp(cue.startTime)) --> \(formatVTTTimestamp(cue.endTime))")
            result.append(cue.text)
            result.append("")
        }
        return result.joined(separator: "\n")
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

    /// Formats a time interval as SRT timestamp: `HH:MM:SS,mmm`
    private func formatSRTTimestamp(_ seconds: TimeInterval) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Formats a time interval as VTT timestamp: `HH:MM:SS.mmm`
    private func formatVTTTimestamp(_ seconds: TimeInterval) -> String {
        let totalMs = Int(seconds * 1000)
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
