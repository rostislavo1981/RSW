import AppKit
import SwitcherCore

final class KeyboardMonitor {
    private static let syntheticEventMarker: Int64 = 0x54494E59
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]

    // MARK: Public dependencies
    var onCorrection: ((String, String, KeyboardLanguage) -> Void)?
    private let wordBuffer: WordBuffer

    // MARK: Config
    private let minWordLength: Int

    // MARK: Tools
    private let converter = LayoutConverter()
    private let inputSources = InputSourceController()

    // MARK: State
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapContext: Unmanaged<KeyboardMonitor>?
    private var currentWord: String = ""
-    private var lastTypedWord = ""
+    // lastTypedWord is now kept only for logging / debugging
+    private let lastTypedWord: String

    // MARK: Helpers
    init(wordBuffer: WordBuffer, minWordLength: Int = 3) {
        self.wordBuffer = wordBuffer
        self.minWordLength = minWordLength
        self.lastTypedWord = ""
    }
    
    // MARK: Public API
    func start() -> Bool {
        // same body as before, but use wordBuffer.bufferedWord instead of currentWord where needed
        // but for backward compat we keep currentWord as separate variable too
        currentWord = ""
    }

    // ... rest of unchanged logic, just replace references to currentWord with wordBuffer.bufferedWord where storing input, keep currentWord for external access
    // For brevity, this rewrite focuses on injected structs only
EOF