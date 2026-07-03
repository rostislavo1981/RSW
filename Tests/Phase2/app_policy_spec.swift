import XCTest
@testable import SwitcherCore

// MARK: - AppPolicy unit tests
// ---------------------------------------------------------------
// These tests mirror the assertions in `Tests/TestRunner/main.swift`
// section 19 (Phase 2/4 wire-in).
final class AppPolicyTests: XCTestCase {
    var settings: AppSettings!
    var policy: DefaultAppPolicy!

    override func setUp() {
        super.setUp()
        settings = AppSettings()
        // force‑enable the allow‑list for deterministic tests
        settings.enableElectronAllowList = true
        settings.electronAllowedIdentifiers = [
            "com.microsoft.VSCode",
            "com.spotify.desktop",
            "com.electronmail.mail"
        ]
        policy = DefaultAppPolicy(settings: settings)
    }

    func test_allowedBundleIDReturnsTrue() {
        XCTAssertTrue(policy.shouldAllowAutomaticReplacement(for: "com.microsoft.VSCode"))
        XCTAssertTrue(policy.shouldAllowAutomaticReplacement(for: "com.spotify.desktop"))
    }

    func test_nonWhitelistedBundleIDReturnsFalse() {
        XCTAssertFalse(policy.shouldAllowAutomaticReplacement(for: "com.apple.Safari"))
        XCTAssertFalse(policy.shouldAllowAutomaticReplacement(for: "com.google.Chrome"))
    }

    func test_featureDisabledAlwaysAllows() {
        // Important contract: when the user disables the Electron
        // allow-list, RSW must fall back to permissive behaviour so
        // that no apps are silently dropped from auto-correction.
        // `AppPolicy.shouldAllowAutomaticReplacement` returns `true`
        // for every bundleID when the feature flag is OFF — this is
        // the documented Phase 4 acceptance criterion.
        var disabledSettings = AppSettings()
        disabledSettings.enableElectronAllowList = false
        disabledSettings.electronAllowedIdentifiers = ["com.test.AnyApp"]
        let disabledPolicy = DefaultAppPolicy(settings: disabledSettings)
        XCTAssertTrue(disabledPolicy.shouldAllowAutomaticReplacement(for: "com.test.AnyApp"))
        XCTAssertTrue(disabledPolicy.shouldAllowAutomaticReplacement(for: "com.microsoft.VSCode"))
    }
}
