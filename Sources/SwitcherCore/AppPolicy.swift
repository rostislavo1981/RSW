import AppKit

public protocol AppPolicy {
    func shouldAllowAutomaticReplacement(for bundleID: String) -> Bool
}

public final class DefaultAppPolicy: AppPolicy {
    private let settings: AppSettings

    private static let knownElectronIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.spotify.desktop",
        "com.electronmail.mail",
        "com.slack.Slack",
        "com.discord",
        "com.electron.electron",
        "com.electron.app",
        "com.github.electron",
        "com.atom.electron",
        "com.postman.linux",
        "com.ridafkih.MemoryGraph"
    ]

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func shouldAllowAutomaticReplacement(for bundleID: String) -> Bool {
        guard settings.enableElectronAllowList else { return true }

        if isKnownElectronApp(bundleID) {
            return settings.electronAllowedIdentifiers.contains(bundleID)
        }

        return true
    }

    private func isKnownElectronApp(_ bundleID: String) -> Bool {
        if Self.knownElectronIdentifiers.contains(bundleID) {
            return true
        }

        if bundleID.contains(".electron.") || bundleID.contains(".electron-") {
            return true
        }

        return false
    }
}
