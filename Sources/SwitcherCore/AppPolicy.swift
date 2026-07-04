import AppKit

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
        // Если фича allow-list ВЫКЛЮЧЕНА — пропускаем все приложения.
        // (Раньше здесь ошибочно стоял `return false`, из-за чего RSW
        // запрещал замену ВЕЗДЕ, даже когда feature off.)
        guard settings.enableElectronAllowList else { return true }
        // Включена: пропускаем только bundle ID из allow-list.
        return settings.electronAllowedIdentifiers.contains(bundleID)
    }
}