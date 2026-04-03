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
}
