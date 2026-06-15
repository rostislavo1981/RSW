import AppKit
import ApplicationServices
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = KeyboardMonitor()
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var lastCorrection: (source: String, converted: String, language: KeyboardLanguage)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()

        monitor.onCorrection = { [weak self] source, replacement, language in
            self?.lastCorrection = (source: source, converted: replacement, language: language)
        }

        requestAccessibilityPermission()
        if !monitor.start() {
            statusItem.button?.title = "⌨︎!"
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨︎"
        statusItem.button?.toolTip = "Tiny Switcher"

        let menu = NSMenu()
        enabledItem = NSMenuItem(
            title: "Автопереключение",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = .on
        menu.addItem(enabledItem)

        let addLastItem = NSMenuItem(
            title: "Добавить последнее слово в словарь",
            action: #selector(addLastToDictionary),
            keyEquivalent: ""
        )
        addLastItem.target = self
        menu.addItem(addLastItem)

        let addCustomItem = NSMenuItem(
            title: "Добавить слово вручную…",
            action: #selector(addCustomWord),
            keyEquivalent: ""
        )
        addCustomItem.target = self
        menu.addItem(addCustomItem)

        menu.addItem(NSMenuItem.separator())

        let permissionItem = NSMenuItem(
            title: "Открыть настройки Accessibility",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        enabledItem.state = monitor.isEnabled ? .on : .off
        statusItem.button?.title = monitor.isEnabled ? "⌨︎" : "⌨︎−"
    }

    @objc private func addLastToDictionary() {
        guard let correction = lastCorrection else {
            showAlert(message: "Нет последнего исправления для добавления.")
            return
        }
        WordDictionary.shared.add(correction.converted, language: correction.language)
        let lang = correction.language == .russian ? "русское" : "английское"
        showAlert(message: "«\(correction.converted)» добавлено в \(lang) словарь.")
    }

    @objc private func addCustomWord() {
        let alert = NSAlert()
        alert.messageText = "Добавить слово в словарь"
        alert.informativeText = "Введите слово. Язык определится автоматически."
        alert.addButton(withTitle: "Добавить")
        alert.addButton(withTitle: "Отмена")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = textField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let word = textField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else {
            showAlert(message: "Слово не может быть пустым.")
            return
        }

        let lower = word.lowercased()
        let dict = WordDictionary.shared
        if lower.allSatisfy({ $0.isASCII && $0.isLetter }) {
            dict.add(lower, language: .english)
            showAlert(message: "«\(word)» добавлено в английский словарь.")
        } else if lower.allSatisfy({ LayoutConverter.isRussianCharacter($0) }) {
            dict.add(lower, language: .russian)
            showAlert(message: "«\(word)» добавлено в русский словарь.")
        } else {
            showAlert(message: "Не удалось определить язык слова «\(word)».")
        }
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
