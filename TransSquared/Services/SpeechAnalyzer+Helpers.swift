import Speech

extension SpeechAnalyzer {
    /// Ensures speech assets are installed for the given modules, downloading if needed.
    static func ensureAssetsInstalled(for modules: [any SpeechModule]) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
    }

    /// Sets contextual strings on the analyzer to bias recognition toward custom vocabulary.
    /// Does nothing if the array is empty.
    func setContextualStrings(_ strings: [String]) async throws {
        guard !strings.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        try await setContext(context)
    }
}
