import Foundation

/// Терминальные приложения, в которых RSW полностью отключён (pass-through):
/// не исправляет текст, не буферизует ввод, не переключает выделение.
///
/// Список и предикат вынесены в `SwitcherCore`, чтобы их можно было
/// тестировать в `TestRunner` (цель `RSW` туда не импортируется). Раньше
/// набор жил в `KeyboardMonitor` и был недоступен для проверки.
public enum TerminalApps {
    public static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]

    public static func isTerminal(_ bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }
}
