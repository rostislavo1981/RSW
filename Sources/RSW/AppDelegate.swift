import AppKit
import ApplicationServices
import SwitcherCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = KeyboardMonitor()
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var lastCorrection: (source: String, converted: String, language: KeyboardLanguage)?
    private var settingsWindow: NSWindow?
    private var tooltipResetTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()

        monitor.onCorrection = { [weak self] source, replacement, language in
            self?.lastCorrection = (source: source, converted: replacement, language: language)
            rswDebugLog("[rswitcher] исправление: исходнаяДлина=\(source.count), новаяДлина=\(replacement.count), язык=\(language)")
            if AppSettings.shared.showTooltip {
                self?.showCorrectionTooltip(source: source, replacement: replacement)
            }
        }

        requestAccessibilityPermission()

        let trusted = AXIsProcessTrusted()
        RSWDiagnosticLogger.shared.log("app_launch", [
            "accessibilityTrusted": trusted,
            "autoSwitchEnabled": monitor.isEnabled
        ])
        fputs("[rswitcher] Доступ Accessibility: \(trusted)\n", stderr)

        if !monitor.start() {
            statusItem.button?.title = "⌨︎!"
            fputs("[rswitcher] Не удалось создать event tap\n", stderr)
        } else {
            fputs("[rswitcher] Event tap создан\n", stderr)
        }
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨︎"
        statusItem.button?.toolTip = "rswitcher"

        let menu = NSMenu()

        enabledItem = NSMenuItem(
            title: "Автопереключение",
            action: #selector(toggleEnabled),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = monitor.isEnabled ? .on : .off
        statusItem.button?.title = monitor.isEnabled ? "⌨︎" : "⌨︎−"
        menu.addItem(enabledItem)

        menu.addItem(NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())

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
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        enabledItem.state = monitor.isEnabled ? .on : .off
        statusItem.button?.title = monitor.isEnabled ? "⌨︎" : "⌨︎−"
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "rswitcher — Настройки"
            window.styleMask = [.titled, .closable]
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

    private func showCorrectionTooltip(source: String, replacement: String) {
        guard let button = statusItem.button else { return }
        tooltipResetTimer?.invalidate()
        button.title = "⌨︎ \(replacement)"
        let restored = monitor.isEnabled ? "⌨︎" : "⌨︎−"
        tooltipResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            button.title = restored
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
}

import SwiftUI
