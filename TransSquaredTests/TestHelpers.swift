//
//  TestHelpers.swift
//  TransSquaredTests
//

import Foundation
import Testing
@testable import TransSquared

/// Creates an ephemeral `UserDefaults` suite that won't pollute the app's real settings.
@MainActor
func makeTestViewModel() -> SessionViewModel {
    let suiteName = "com.transsquared.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return SessionViewModel(defaults: defaults)
}

/// Anchor class used to locate the test bundle at runtime.
final class TestBundleAnchor {}
