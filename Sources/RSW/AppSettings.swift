import Foundation

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var autoSwitchEnabled: Bool {
        didSet { save() }
    }

    @Published var minWordLength: Int {
        didSet { save() }
    }

    @Published var showTooltip: Bool {
        didSet { save() }
    }

    @Published var manualSwitchKeyCode: Int {
        didSet { save() }
    }

    @Published var manualSwitchModifiers: Int {
        didSet { save() }
    }

    @Published var excludedKeys: [Int] {
        didSet { save() }
    }

    @Published var launchAtLogin: Bool {
        didSet { save() }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let minWordLength = "minWordLength"
        static let showTooltip = "showTooltip"
        static let manualSwitchKeyCode = "manualSwitchKeyCode"
        static let manualSwitchModifiers = "manualSwitchModifiers"
        static let excludedKeys = "excludedKeys"
        static let launchAtLogin = "launchAtLogin"
    }

    init() {
        let defs = UserDefaults.standard

        defs.register(defaults: [
            Keys.autoSwitchEnabled: true,
            Keys.minWordLength: 3,
            Keys.showTooltip: true,
            Keys.manualSwitchKeyCode: 49,
            Keys.manualSwitchModifiers: 0,
            Keys.excludedKeys: [56, 60, 61],
            Keys.launchAtLogin: false
        ])

        self.autoSwitchEnabled = defs.bool(forKey: Keys.autoSwitchEnabled)
        self.minWordLength = defs.integer(forKey: Keys.minWordLength)
        self.showTooltip = defs.bool(forKey: Keys.showTooltip)
        self.manualSwitchKeyCode = defs.integer(forKey: Keys.manualSwitchKeyCode)
        self.manualSwitchModifiers = defs.integer(forKey: Keys.manualSwitchModifiers)
        self.excludedKeys = defs.array(forKey: Keys.excludedKeys) as? [Int] ?? [56, 60, 61]
        self.launchAtLogin = defs.bool(forKey: Keys.launchAtLogin)
    }

    func isExcludedKey(_ keyCode: Int) -> Bool {
        excludedKeys.contains(keyCode)
    }

    func save() {
        defaults.set(autoSwitchEnabled, forKey: Keys.autoSwitchEnabled)
        defaults.set(minWordLength, forKey: Keys.minWordLength)
        defaults.set(showTooltip, forKey: Keys.showTooltip)
        defaults.set(manualSwitchKeyCode, forKey: Keys.manualSwitchKeyCode)
        defaults.set(manualSwitchModifiers, forKey: Keys.manualSwitchModifiers)
        defaults.set(excludedKeys, forKey: Keys.excludedKeys)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
    }
}
