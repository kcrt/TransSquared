import Foundation
import Speech
import Translation
import os

private let logger = Logger.app("Languages")

// MARK: - Language Control

extension SessionViewModel {

    /// Triggers a background download of speech recognition assets for the given locale if not already installed.
    /// Safe to call multiple times — the system consolidates redundant requests.
    func downloadSpeechAssetsIfNeeded(for locale: Locale) {
        guard !installedSourceLocaleIdentifiers.contains(locale.identifier),
              !downloadingSourceLocaleIdentifiers.contains(locale.identifier) else { return }
        downloadingSourceLocaleIdentifiers.insert(locale.identifier)
        let localeID = locale.identifier
        let log = logger
        let task = Task.detached {
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
            let succeeded: Bool
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try Task.checkCancellation()
                    log.info("Starting speech asset download for \(localeID)")
                    try await request.downloadAndInstall()
                    log.info("Speech asset download completed for \(localeID)")
                }
                succeeded = true
            } catch is CancellationError {
                log.info("Speech asset download cancelled for \(localeID)")
                succeeded = false
            } catch {
                log.error("Speech asset download failed for \(localeID): \(error.localizedDescription)")
                succeeded = false
            }
            let didSucceed = succeeded
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.downloadingSourceLocaleIdentifiers.remove(localeID)
                self.speechDownloadTasks.removeValue(forKey: localeID)
                if didSucceed {
                    self.installedSourceLocaleIdentifiers.insert(localeID)
                }
            }
        }
        speechDownloadTasks[locale.identifier] = task
    }

    /// Triggers a proactive translation model download for the given target language.
    /// Uses `TranslationSession.prepareTranslation()` via the `.translationTask()` modifier in ContentView.
    /// Unlike speech models (which download silently), translation models require user confirmation via a system dialog.
    /// If the download dialog does not appear, the user can install models manually from
    /// System Settings > General > Language & Region > Translation Languages.
    func prepareTranslationModelIfNeeded(for languageIdentifier: String) {
        guard targetLanguageDownloadStatus[languageIdentifier] != true else { return }

        let targetLang = Locale.Language(identifier: languageIdentifier)
        let source = sourceLocale.language
        logger.info("Requesting translation model preparation for '\(languageIdentifier)' (source: \(self.sourceLocaleIdentifier))")

        // Clear then set config so SwiftUI detects a nil→non-nil transition.
        translationPreparationConfig = nil
        translationPreparationConfig = TranslationSession.Configuration(source: source, target: targetLang)
    }

    func swapLanguages() {
        guard !isSessionActive else { return }

        let oldSourceIdentifier = sourceLocaleIdentifier
        let oldSourceLangCode = sourceLocale.language.languageCode
        let oldTargetIdentifier = targetLanguageIdentifier

        logger.debug("swapLanguages: oldSource='\(oldSourceIdentifier)' (langCode=\(oldSourceLangCode?.identifier ?? "nil")), oldTarget='\(oldTargetIdentifier)'")

        // Find a source locale matching the old target language.
        // Prefer: exact identifier match → user's region → no region → first match
        let targetLang = Locale.Language(identifier: oldTargetIdentifier)
        let targetLangCode = targetLang.languageCode
        logger.debug("swapLanguages: targetLang parsed: languageCode=\(targetLangCode?.identifier ?? "nil"), region=\(targetLang.region?.identifier ?? "nil")")

        let candidates = supportedSourceLocales.filter {
            $0.language.languageCode == targetLangCode
        }
        logger.debug("swapLanguages: candidates=[\(candidates.map(\.identifier).joined(separator: ", "))]")

        let userRegion = Locale.current.region
        logger.debug("swapLanguages: userRegion=\(userRegion?.identifier ?? "nil")")

        let likelyRegion = Self.likelyRegion(for: oldTargetIdentifier)
        logger.debug("swapLanguages: likelyRegion=\(likelyRegion?.identifier ?? "nil")")

        let newSource = candidates.first(where: { $0.identifier == oldTargetIdentifier })
            ?? candidates.first(where: { $0.language.region == targetLang.region && targetLang.region != nil })
            ?? candidates.first(where: { $0.language.region == likelyRegion })
            ?? candidates.first(where: { $0.language.region == userRegion })
            ?? candidates.first(where: { $0.identifier.hasPrefix((targetLangCode?.identifier ?? "") + "_US") })
            ?? candidates.first
        if let newSource {
            logger.debug("swapLanguages: selected newSource='\(newSource.identifier)'")
            sourceLocaleIdentifier = newSource.identifier
            // Use the old source language code as target
            if let code = oldSourceLangCode {
                logger.debug("swapLanguages: setting targetLanguageIdentifier='\(code.identifier)'")
                targetLanguageIdentifier = code.identifier
            }
            Task {
                await updateTargetLanguages()
            }
        } else {
            logger.warning("swapLanguages: no matching source locale found for targetLangCode=\(targetLangCode?.identifier ?? "nil")")
            let langName = Locale.current.localizedString(forIdentifier: oldTargetIdentifier) ?? oldTargetIdentifier
            errorMessage = String(
                localized: "Cannot swap: \(langName) is not available as a speech recognition source language.",
                comment: "Error shown when the user tries to swap languages but the target language is not supported for speech recognition input"
            )
        }

        logger.debug("swapLanguages: result source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")
    }

    func updateTargetLanguages() async {
        logger.debug("updateTargetLanguages: current source='\(self.sourceLocaleIdentifier)', target='\(self.targetLanguageIdentifier)'")

        let availability = LanguageAvailability()
        let allLangs = await availability.supportedLanguages
        var available: [Locale.Language] = []
        var statusMap: [String: Bool] = [:]
        for lang in allLangs {
            if lang.languageCode != sourceLocale.language.languageCode {
                let status = await availability.status(from: sourceLocale.language, to: lang)
                if status != .unsupported {
                    available.append(lang)
                    statusMap[lang.minimalIdentifier] = (status == .installed)
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
        targetLanguageDownloadStatus = statusMap
        logger.info("updateTargetLanguages: \(available.count) target languages available")

        // Ensure current target is still valid
        let exactMatch = available.contains(where: { $0.minimalIdentifier == targetLanguageIdentifier })
        logger.debug("updateTargetLanguages: exact match for '\(self.targetLanguageIdentifier)' in available: \(exactMatch)")

        if !exactMatch {
            // Try matching by language code only (e.g. "en" matches "en-US")
            let targetLang = Locale.Language(identifier: targetLanguageIdentifier)
            let candidates = available.filter { $0.languageCode == targetLang.languageCode }
            logger.debug("updateTargetLanguages: fallback candidates for langCode=\(targetLang.languageCode?.identifier ?? "nil"): [\(candidates.map(\.minimalIdentifier).joined(separator: ", "))]")

            if let match = Self.bestLanguageMatch(from: candidates, for: targetLanguageIdentifier) {
                logger.debug("updateTargetLanguages: re-mapped target '\(self.targetLanguageIdentifier)' → '\(match.minimalIdentifier)'")
                targetLanguageIdentifier = match.minimalIdentifier
            } else if let first = available.first {
                logger.debug("updateTargetLanguages: no candidate match, defaulting to '\(first.minimalIdentifier)'")
                let requestedName = Locale.current.localizedString(forIdentifier: targetLanguageIdentifier) ?? targetLanguageIdentifier
                let fallbackName = Locale.current.localizedString(forIdentifier: first.minimalIdentifier) ?? first.minimalIdentifier
                targetLanguageIdentifier = first.minimalIdentifier
                errorMessage = String(
                    localized: "\(requestedName) is not available as a translation target. Changed to \(fallbackName).",
                    comment: "Error shown when the desired translation target language is unavailable and was automatically changed to a fallback"
                )
            }
        }

        logger.debug("updateTargetLanguages: final target='\(self.targetLanguageIdentifier)'")
    }

    /// Refreshes only the installed-status for translation models (lightweight, no full reload).
    /// Called when the app becomes active so that models installed via System Settings are detected.
    func refreshTranslationInstallStatus() async {
        let availability = LanguageAvailability()
        var statusMap: [String: Bool] = [:]
        for lang in supportedTargetLanguages {
            let status = await availability.status(from: sourceLocale.language, to: lang)
            statusMap[lang.minimalIdentifier] = (status == .installed)
        }
        targetLanguageDownloadStatus = statusMap
    }

    // MARK: - Target Language Count

    func addTargetLanguage() {
        guard targetCount < Self.maxTargetCount else { return }
        targetCount += 1
        // Pick a default language not already selected
        let used = Set(targetLanguageIdentifiers.prefix(targetCount - 1))
        if let available = supportedTargetLanguages.first(where: { !used.contains($0.minimalIdentifier) }) {
            if targetLanguageIdentifiers.count < targetCount {
                targetLanguageIdentifiers.append(available.minimalIdentifier)
            } else {
                targetLanguageIdentifiers[targetCount - 1] = available.minimalIdentifier
            }
        }
    }

    func removeTargetLanguage() {
        guard targetCount > 1 else { return }
        targetCount -= 1
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
