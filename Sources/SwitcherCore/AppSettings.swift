import Foundation
import CoreGraphics
import ServiceManagement

// MARK: – Manual switch configuration
public enum ManualSwitchTrigger: String, CaseIterable, Identifiable {
    case doubleModifier
    case key

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .doubleModifier: return "Двойное нажатие модификатора"
        case .key: return "Клавиша / комбинация"
        }
    }
}

public enum ManualSwitchModifier: Int, CaseIterable, Identifiable {
    case option = 58          // левый ⌥
    case rightOption = 61
    case shift = 56           // левый ⇧
    case command = 55         // ⌘
    case control = 59         // ⌃

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .rightOption: return "⌥ Option (правый)"
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        }
    }

    public var maskBit: UInt64 {
        switch self {
        case .option, .rightOption: return CGEventFlags.maskAlternate.rawValue
        case .shift: return CGEventFlags.maskShift.rawValue
        case .command: return CGEventFlags.maskCommand.rawValue
        case .control: return CGEventFlags.maskControl.rawValue
        }
    }

    public var keyCodes: Set<Int> {
        switch self {
        case .option:      return [58, 61]
        case .rightOption: return [58, 61]
        case .shift:       return [56, 60]
        case .command:     return [55, 54, 63]
        case .control:     return [59, 62]
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    @Published public var manualSwitchTrigger: ManualSwitchTrigger {
        didSet { save() }
    }
    @Published public var manualSwitchModifierKey: Int {
        didSet { save() }
    }
    @Published public var autoSwitchEnabled: Bool {
        didSet { save() }
    }
    @Published public var minWordLength: Int {
        didSet { save() }
    }
    @Published public var showTooltip: Bool {
        didSet { save() }
    }
    @Published public var manualSwitchKeyCode: Int {
        didSet { save() }
    }
    @Published public var manualSwitchModifiers: Int {
        didSet { save() }
    }
    @Published public var excludedKeys: [Int] {
        didSet { save() }
    }
    @Published public var launchAtLogin: Bool {
        didSet {
            save()
            applyLaunchAtLogin()
        }
    }

    @Published public var enableElectronAllowList: Bool = true
    @Published public var electronAllowedIdentifiers: [String] = []

    // MARK: – Persistence
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let minWordLength = "minWordLength"
        static let showTooltip = "showTooltip"
        static let manualSwitchKeyCode = "manualSwitchKeyCode"
        static let manualSwitchModifiers = "manualSwitchModifiers"
        static let manualSwitchTrigger = "manualSwitchTrigger"
        static let manualSwitchModifierKey = "manualSwitchModifierKey"
        static let excludedKeys = "excludedKeys"
        static let launchAtLogin = "launchAtLogin"
        static let enableElectronAllowList = "enableElectronAllowList"
        static let electronAllowedIdentifiers = "electronAllowedIdentifiers"
    }

    init() {
        let defs = UserDefaults.standard
        defs.register(defaults: [
            Keys.autoSwitchEnabled: true,
            Keys.minWordLength: 3,
            Keys.showTooltip: true,
            Keys.manualSwitchKeyCode: 49,
            Keys.manualSwitchModifiers: 0,
            Keys.manualSwitchTrigger: ManualSwitchTrigger.doubleModifier.rawValue,
            Keys.manualSwitchModifierKey: ManualSwitchModifier.option.rawValue,
            Keys.excludedKeys: [56, 60, 61],
            Keys.launchAtLogin: false,
            Keys.enableElectronAllowList: true,
            Keys.electronAllowedIdentifiers: [] as [String]
        ])

        self.autoSwitchEnabled = defs.bool(forKey: Keys.autoSwitchEnabled)
        self.minWordLength = defs.integer(forKey: Keys.minWordLength)
        self.showTooltip = defs.bool(forKey: Keys.showTooltip)
        self.manualSwitchKeyCode = defs.integer(forKey: Keys.manualSwitchKeyCode)
        self.manualSwitchModifiers = defs.integer(forKey: Keys.manualSwitchModifiers)
        self.manualSwitchTrigger = ManualSwitchTrigger(rawValue: defs.string(forKey: Keys.manualSwitchTrigger) ?? "") ?? .doubleModifier
        self.manualSwitchModifierKey = defs.integer(forKey: Keys.manualSwitchModifierKey)
        self.excludedKeys = defs.array(forKey: Keys.excludedKeys) as? [Int] ?? [56, 60, 61]
        self.launchAtLogin = defs.bool(forKey: Keys.launchAtLogin)
        self.enableElectronAllowList = defs.bool(forKey: Keys.enableElectronAllowList)
        self.electronAllowedIdentifiers = defs.stringArray(forKey: Keys.electronAllowedIdentifiers) ?? []

        // Привести сохранённый флаг к фактическому состоянию системы:
        // пользователь мог изменить автозапуск через System Settings.
        let actuallyEnabled = SMAppService.mainApp.status == .enabled
        if actuallyEnabled != self.launchAtLogin {
            self.launchAtLogin = actuallyEnabled
        }
    }

    public func isExcludedKey(_ keyCode: Int) -> Bool {
        excludedKeys.contains(keyCode)
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            fputs("[rsw] Ошибка автозапуска: \(error.localizedDescription)\n", stderr)
        }
    }

    /// Persists all published properties to `UserDefaults`.
    func save() {
        defaults.set(autoSwitchEnabled, forKey: Keys.autoSwitchEnabled)
        defaults.set(minWordLength, forKey: Keys.minWordLength)
        defaults.set(showTooltip, forKey: Keys.showTooltip)
        defaults.set(manualSwitchKeyCode, forKey: Keys.manualSwitchKeyCode)
        defaults.set(manualSwitchModifiers, forKey: Keys.manualSwitchModifiers)
        defaults.set(manualSwitchTrigger.rawValue, forKey: Keys.manualSwitchTrigger)
        defaults.set(manualSwitchModifierKey, forKey: Keys.manualSwitchModifierKey)
        defaults.set(excludedKeys, forKey: Keys.excludedKeys)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(enableElectronAllowList, forKey: Keys.enableElectronAllowList)
        defaults.set(electronAllowedIdentifiers as [String], forKey: Keys.electronAllowedIdentifiers)
    }
}