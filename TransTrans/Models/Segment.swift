import Foundation
import SwiftData

@Model
final class Segment {
    var index: Int
    var timestamp: TimeInterval
    var originalText: String
    var translatedText: String?

    init(index: Int, timestamp: TimeInterval, originalText: String, translatedText: String? = nil) {
        self.index = index
        self.timestamp = timestamp
        self.originalText = originalText
        self.translatedText = translatedText
    }
}
