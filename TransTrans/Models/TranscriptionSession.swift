import Foundation
import SwiftData

@Model
final class TranscriptionSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var sourceLocale: String
    var targetLocale: String
    var processingMode: String
    @Relationship(deleteRule: .cascade) var segments: [Segment]

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        sourceLocale: String,
        targetLocale: String,
        processingMode: String = "onDevice"
    ) {
        self.id = id
        self.startedAt = startedAt
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.processingMode = processingMode
        self.segments = []
    }
}
