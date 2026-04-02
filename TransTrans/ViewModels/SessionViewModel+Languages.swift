import Foundation
import Translation
import os

private let logger = Logger.app("Languages")

// MARK: - Language Control

extension SessionViewModel {

    func swapLanguages() {
        guard !isSessionActive else { return }

        let oldSourceIdentifier = sourceLocaleIdentifier
        let oldSourceLangCode = sourceLocale.language.languageCode
        let oldTargetIdentifier = targetLanguageIdentifier

        logger.info("swapLanguages: oldSource='\(oldSourceIdentifier)' (langCode=\(oldSourceLangCode?.identifier ?? "nil")), oldTarget='\(oldTargetIdentifier)'")

        // Find a source locale matching the old target language.
        // Prefer: exact identifier match → user's region → no region → first match
        let targetLang = Locale.Language(identifier: oldTargetIdentifier)
        let targetLangCode = targetLang.languageCode
        logger.info("swapLanguages: targetLang parsed: languageCode=\(targetLangCode?.identifier ?? "nil"), region=\(targetLang.region?.identifier ?? "nil")")

        let candidates = supportedSourceLocales.filter {
            $0.language.languageCode == targetLangCode
        }
        logger.info("swapLanguages: candidates=[\(candidates.map(\.identifier).joined(separator: ", "))]")

        let userRegion = Locale.current.region
        logger.info("swapLanguages: userRegion=\(userRegion?.identifier ?? "nil")")

        let likelyRegion = Self.likelyRegion(for: oldTargetIdentifier)
        logger.info("swapLanguages: likelyRegion=\(likelyRegion?.identifier ?? "nil")")

        let newSource = candidates.first(where: { $0.identifier == oldTargetIdentifier })
            ?? candidates.first(where: { $0.language.region == targetLang.region && targetLang.region != nil })
            ?? candidates.first(where: { $0.language.region == likelyRegion })
            ?? candidates.first(where: { $0.language.region == userRegion })
            ?? candidates.first(where: { $0.identifier.hasPrefix((targetLangCode?.identifier ?? "") + "_US") })
            ?? candidates.first
        if let newSource {
            logger.info("swapLanguages: selected newSource='\(newSource.identifier)'")
            sourceLocaleIdentifier = newSource.identifier
            // Use the old source language code as target
            if let code = oldSourceLangCode {
                logger.info("swapLanguages: setting targetLanguageIdentifier='\(code.identifier)'")
                targetLanguageIdentifier = code.identifier
            }
            Task {
                await updateTargetLanguages()
            }
        } else {
            logger.warning("swapLanguages: no matching source locale found for targetLangCode=\(targetLangCode?.identifier ?? "nil")")
        }

        logger.info("swapLanguages: result source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")
    }

    func updateTargetLanguages() async {
        logger.info("updateTargetLanguages: current source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")

        let availability = LanguageAvailability()
        let allLangs = await availability.supportedLanguages
        var available: [Locale.Language] = []
        for lang in allLangs {
            if lang.languageCode != sourceLocale.language.languageCode {
                let status = await availability.status(from: sourceLocale.language, to: lang)
                if status != .unsupported {
                    available.append(lang)
                }
            }
        }
        // Sort by localized display name for a user-friendly order
        available.sort { lhs, rhs in
            let lhsName = Locale.current.localizedString(forIdentifier: lhs.minimalIdentifier) ?? lhs.minimalIdentifier
            let rhsName = Locale.current.localizedString(forIdentifier: rhs.minimalIdentifier) ?? rhs.minimalIdentifier
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
        supportedTargetLanguages = available
        logger.info("updateTargetLanguages: \(available.count) target languages available")

        // Ensure current target is still valid
        let exactMatch = available.contains(where: { $0.minimalIdentifier == targetLanguageIdentifier })
        logger.info("updateTargetLanguages: exact match for '\(self.targetLanguageIdentifier)' in available: \(exactMatch)")

        if !exactMatch {
            // Try matching by language code only (e.g. "en" matches "en-US")
            let targetLang = Locale.Language(identifier: targetLanguageIdentifier)
            let candidates = available.filter { $0.languageCode == targetLang.languageCode }
            logger.info("updateTargetLanguages: fallback candidates for langCode=\(targetLang.languageCode?.identifier ?? "nil"): [\(candidates.map(\.minimalIdentifier).joined(separator: ", "))]")

            if let match = Self.bestLanguageMatch(from: candidates, for: targetLanguageIdentifier) {
                logger.info("updateTargetLanguages: re-mapped target '\(self.targetLanguageIdentifier)' → '\(match.minimalIdentifier)'")
                targetLanguageIdentifier = match.minimalIdentifier
            } else if let first = available.first {
                logger.info("updateTargetLanguages: no candidate match, defaulting to '\(first.minimalIdentifier)'")
                targetLanguageIdentifier = first.minimalIdentifier
            }
        }

        logger.info("updateTargetLanguages: final target='\(self.targetLanguageIdentifier)'")
    }

    // MARK: - Locale Resolution Helpers

    /// Extracts the likely region from a language identifier via its maximal form.
    /// e.g. "en" → maximalIdentifier "en-Latn-US" → Region("US")
    static func likelyRegion(for identifier: String) -> Locale.Region? {
        let maximal = Locale.Language(identifier: identifier).maximalIdentifier
        return maximal.split(separator: "-").last.map { Locale.Region(String($0)) }
    }

    /// Picks the best match from a list of `Locale.Language` candidates, preferring
    /// user region → no region → likely default region → first available.
    static func bestLanguageMatch(
        from candidates: [Locale.Language],
        for identifier: String
    ) -> Locale.Language? {
        let userRegion = Locale.current.region
        let likely = likelyRegion(for: identifier)
        return candidates.first(where: { $0.region == userRegion })
            ?? candidates.first(where: { $0.region == nil })
            ?? candidates.first(where: { $0.region == likely })
            ?? candidates.first
    }
}
