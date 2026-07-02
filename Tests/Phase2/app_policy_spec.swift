import XCTest
@testable import SwitcherCore

// MARK: - AppPolicy unit tests
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
    
    func test_featureDisabledAlwaysFalse() {
        var disabledSettings = AppSettings()
        disabledSettings.enableElectronAllowList = false
        disabledSettings.electronAllowedIdentifiers = ["com.test.AnyApp"]
        let disabledPolicy = DefaultAppPolicy(settings: disabledSettings)
        XCTAssertFalse(disabledPolicy.shouldAllowAutomaticReplacement(for: "com.test.AnyApp"))
    }
}