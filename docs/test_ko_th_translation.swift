// Test script for Korean → Thai translation using Apple's Translation framework.
//
// Compile and run:
//   swiftc -parse-as-library -framework Translation docs/test_ko_th_translation.swift -o /tmp/test_translation && /tmp/test_translation

import Foundation
import Translation

// MARK: - Test pairs

struct LanguagePair {
    let sourceId: String
    let targetId: String
    let label: String
    let testSentence: String

    var source: Locale.Language { Locale.Language(identifier: sourceId) }
    var target: Locale.Language { Locale.Language(identifier: targetId) }
}

let pairs: [LanguagePair] = [
    LanguagePair(sourceId: "ko", targetId: "ja", label: "Korean → Japanese (control)",
                 testSentence: "안녕하세요. 오늘 날씨가 좋습니다."),
    LanguagePair(sourceId: "ja", targetId: "th", label: "Japanese → Thai (control)",
                 testSentence: "こんにちは。今日はいい天気です。"),
    LanguagePair(sourceId: "ko", targetId: "th", label: "Korean → Thai (problem pair)",
                 testSentence: "안녕하세요. 오늘 날씨가 좋습니다."),
]

// MARK: - Helpers

func statusString(_ status: LanguageAvailability.Status) -> String {
    switch status {
    case .installed: return "installed"
    case .supported: return "supported"
    case .unsupported: return "unsupported"
    @unknown default: return "unknown(\(status))"
    }
}

// MARK: - Main

@main
struct TranslationTest {
    static func main() async {
        print("=== Translation Framework Test ===")
        print("Date: \(Date())")
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print()

        // Step 1: Check LanguageAvailability for all pairs
        print("--- Step 1: LanguageAvailability.status() ---")
        let availability = LanguageAvailability()

        for pair in pairs {
            let status = await availability.status(from: pair.source, to: pair.target)
            let icon: String
            switch status {
            case .installed: icon = "✅"
            case .supported: icon = "⚠️"
            case .unsupported: icon = "❌"
            @unknown default: icon = "❓"
            }
            print("  \(icon) \(pair.label): \(statusString(status))")
        }
        print()

        // Step 2: English pivot status
        print("--- Step 2: English pivot pairs ---")
        let pivotPairs: [(String, String, String)] = [
            ("ko", "en", "Korean → English"),
            ("en", "ko", "English → Korean"),
            ("th", "en", "Thai → English"),
            ("en", "th", "English → Thai"),
            ("ja", "en", "Japanese → English"),
            ("en", "ja", "English → Japanese"),
        ]
        for (src, tgt, label) in pivotPairs {
            let status = await availability.status(
                from: Locale.Language(identifier: src),
                to: Locale.Language(identifier: tgt)
            )
            let icon: String
            switch status {
            case .installed: icon = "✅"
            case .supported: icon = "⚠️"
            case .unsupported: icon = "❌"
            @unknown default: icon = "❓"
            }
            print("  \(icon) \(label): \(statusString(status))")
        }
        print()

        // Step 3: Translation attempts for ALL pairs
        // Uses TranslationSession(installedSource:target:) regardless of status.
        // For non-installed pairs, this will throw — we capture the error details.
        print("--- Step 3: Translation attempts (all pairs, force) ---")
        for pair in pairs {
            print("  [\(pair.label)]")
            print("    Input : \(pair.testSentence)")

            let status = await availability.status(from: pair.source, to: pair.target)
            print("    LanguageAvailability.status: \(statusString(status))")

            do {
                print("    Creating TranslationSession(installedSource:target:)...")
                let session = TranslationSession(installedSource: pair.source, target: pair.target)
                print("    Session created OK")
                print("    isReady          : \(await session.isReady)")
                print("    canRequestDownloads: \(session.canRequestDownloads)")
                print("    sourceLanguage   : \(String(describing: session.sourceLanguage))")
                print("    targetLanguage   : \(String(describing: session.targetLanguage))")

                print("    Calling translate()...")
                let response = try await session.translate(pair.testSentence)
                print("    Output: \(response.targetText)")
                print("    Response source: \(response.sourceLanguage)")
                print("    Response target: \(response.targetLanguage)")
                print("    ✅ Translation succeeded")
            } catch {
                let nsError = error as NSError
                print("    ❌ FAILED")
                print("    Error        : \(error)")
                print("    Error domain : \(nsError.domain)")
                print("    Error code   : \(nsError.code)")
                print("    Description  : \(nsError.localizedDescription)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("    Underlying   : \(underlying.domain) code=\(underlying.code)")
                }
                for (key, value) in nsError.userInfo where key != NSUnderlyingErrorKey {
                    print("    userInfo[\(key)]: \(value)")
                }
            }
            print()
        }

        // Summary
        print("--- Summary ---")
        print("If ko→th shows 'supported' while ko→ja and ja→th show 'installed',")
        print("this confirms the Translation framework bug documented in")
        print("TRANSLATION_MODEL_PROBLEM.md.")
        print()
        print("To fix manually:")
        print("  System Settings > General > Language & Region > Translation Languages")
        print()
        print("=== Test complete ===")
    }
}
