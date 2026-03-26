import SwiftUI
import UniformTypeIdentifiers
import os

private let logger = Logger(subsystem: "net.kcrt.app.transtrans", category: "Export")

// MARK: - Save / Export

extension SessionViewModel {

    enum SaveContentType {
        case original
        case translation
        case both
    }

    /// Presents an NSSavePanel and writes the selected content to a text file.
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

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFileName(for: contentType)
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Transcript saved to \(url.path)")
        } catch {
            logger.error("Failed to save transcript: \(error.localizedDescription)")
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
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
        sourceLines = []
        for slot in 0..<translationSlots.count {
            translationSlots[slot].lines = []
        }
    }

    func copyAllOriginal() -> String {
        sourceLines.finalizedLines.map(\.text).joined(separator: "\n")
    }

    func copyAllTranslation() -> String {
        let slotCount = min(activeSlotCount, translationSlots.count)
        if slotCount > 1 {
            var result: [String] = []
            for slot in 0..<slotCount {
                let langId = slot < multiTargetLanguageIdentifiers.count
                    ? multiTargetLanguageIdentifiers[slot].uppercased() : "?"
                result.append("[\(langId)]")
                result.append(contentsOf: translationSlots[slot].lines.finalizedLines.map(\.text))
                result.append("")
            }
            return result.joined(separator: "\n")
        }
        return translationSlots.isEmpty ? "" : translationSlots[0].lines.finalizedLines.map(\.text).joined(separator: "\n")
    }

    func copyAllInterleaved() -> String {
        let finalSource = sourceLines.finalizedLines
        let slotCount = min(activeSlotCount, translationSlots.count)
        let slotLines = (0..<slotCount).map { translationSlots[$0].lines.finalizedLines }
        let maxCount = ([finalSource.count] + slotLines.map(\.count)).max() ?? 0

        var result: [String] = []
        for i in 0..<maxCount {
            if i < finalSource.count {
                result.append(finalSource[i].text)
            }
            for slot in 0..<slotCount {
                if i < slotLines[slot].count {
                    result.append(slotLines[slot][i].text)
                }
            }
            result.append("")
        }
        return result.joined(separator: "\n")
    }
}
