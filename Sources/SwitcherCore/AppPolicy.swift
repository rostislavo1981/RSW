import AppKit
import SwitcherCore

/// Protocol that describes the policies governing whether the front‑most
/// application should be allowed to undergo automatic text replacement.
public protocol AppPolicy {
    /// Returns `true` if the given bundle identifier should be treated as an
    /// allowed Electron editor (i.e. auto‑replace is permitted).
    func shouldAllowAutomaticReplacement(for bundleID: String) -> Bool
}

/// Default implementation that uses the shared `AppSettings` singleton to
/// obtain the whitelist of allowed bundle identifiers.
public final class DefaultAppPolicy: AppPolicy {
    private let settings: AppSettings
    
    public init(settings: AppSettings) {
        self.settings = settings
    }
    
    public func shouldAllowAutomaticReplacement(for bundleID: String) -> Bool {
        // If the whitelist feature is disabled, we deny every app.
        guard settings.enableElectronAllowList else { return false }
        // Allow only those bundle IDs that are explicitly listed.
        return settings.electronAllowedIdentifiers.contains(bundleID)
    }
}