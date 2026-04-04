import os

// MARK: - Centralized Logger

extension Logger {
    /// Creates a Logger scoped to the TransTrans app with the given category.
    nonisolated static func app(_ category: String) -> Logger {
        Logger(subsystem: "net.kcrt.app.transtrans", category: category)
    }
}
