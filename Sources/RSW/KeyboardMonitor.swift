import AppKit
import SwitcherCore

final class KeyboardMonitor {
    private static let syntheticEventMarker: Int64 = 0x54494E59

    var onCorrection: ((String, String, KeyboardLanguage) -> Void)?

    private let converter = LayoutConverter()
    private let inputSources = InputSourceController()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentWord = ""
    // Последнее набранное слово (для ручного переключения без выделения).
    private var lastTypedWord = ""

    // Детект двойного нажатия модификатора.
    private var lastModifierTapTime: CFTimeInterval = 0
    private var lastModifierKeyCode: Int64 = -1
    private static let doubleTapInterval: CFTimeInterval = 0.4

    var isEnabled: Bool {
        get { AppSettings.shared.autoSwitchEnabled }
        set { AppSettings.shared.autoSwitchEnabled = newValue }
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: context
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let settings = AppSettings.shared
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // ── Режим «двойное нажатие модификатора» (events типа .flagsChanged) ──
        if type == .flagsChanged {
            if settings.manualSwitchTrigger == .doubleModifier {
                handleModifierDoubleTap(keyCode: keyCode, flags: event.flags, settings: settings)
            }
            // Модификаторы всегда пропускаем дальше без изменений.
            return Unmanaged.passUnretained(event)
        }

        // ── Режим «обычная клавиша/комбинация» (events типа .keyDown) ──
        if settings.manualSwitchTrigger == .key,
           settings.manualSwitchKeyCode >= 0,
           keyCode == settings.manualSwitchKeyCode {
            let flags = event.flags
            var currentMods: NSEvent.ModifierFlags = []
            if flags.contains(.maskCommand) { currentMods.insert(.command) }
            if flags.contains(.maskControl) { currentMods.insert(.control) }
            if flags.contains(.maskAlternate) { currentMods.insert(.option) }
            if flags.contains(.maskShift) { currentMods.insert(.shift) }

            let modMask = NSEvent.ModifierFlags(rawValue: UInt(settings.manualSwitchModifiers))
            // Требуем непустой набор модификаторов, чтобы не перехватывать обычный ввод.
            if !modMask.isEmpty && currentMods.contains(modMask) {
                DispatchQueue.main.async { [weak self] in
                    self?.manualSwitchSelectedText()
                }
                return nil  // поглощаем событие хоткея
            }
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            currentWord = ""
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 {
            if !currentWord.isEmpty { currentWord.removeLast() }
            return Unmanaged.passUnretained(event)
        }

        if settings.isExcludedKey(Int(keyCode)) {
            return Unmanaged.passUnretained(event)
        }

        guard let text = eventText(event), !text.isEmpty else {
            currentWord = ""
            return Unmanaged.passUnretained(event)
        }

        if text.allSatisfy({ $0.isLetter || "`[];',.".contains($0) }) {
            currentWord += text
            lastTypedWord = currentWord
            return Unmanaged.passUnretained(event)
        }

        let word = currentWord
        currentWord = ""

        guard isEnabled, word.count >= settings.minWordLength else {
            return Unmanaged.passUnretained(event)
        }

        guard let correction = converter.convert(word) else {
            return Unmanaged.passUnretained(event)
        }

            fputs("[RSW] \(word) → \(correction.text) (\(correction.language))\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.applyCorrection(word: word, replacement: correction.text, delimiter: text)
            self?.inputSources.select(correction.language)
            self?.onCorrection?(word, correction.text, correction.language)
        }
        return Unmanaged.passUnretained(event)
    }

    private func eventText(_ event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var buffer = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    private func applyCorrection(word: String, replacement: String, delimiter: String) {
        let totalBackspaces = word.count + delimiter.count

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.postBackspaces(totalBackspaces)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.postText(replacement + delimiter)
            }
        }
    }

    private func postBackspaces(_ count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true),
               let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false) {
                down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                down.post(tap: .cgSessionEventTap)
                up.post(tap: .cgSessionEventTap)
            }
        }
    }

    private func postText(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }

    /// Обрабатывает событие .flagsChanged для детекта двойного нажатия модификатора.
    private func handleModifierDoubleTap(keyCode: Int64, flags: CGEventFlags, settings: AppSettings) {
        guard let modifier = ManualSwitchModifier(rawValue: settings.manualSwitchModifierKey) else { return }

        // Интересует только нажатие нужной клавиши-модификатора, не отпускание
        // и не другие модификаторы. На нажатии соответствующий бит флага установлен.
        let isPressOfTargetKey = keyCode == Int64(modifier.rawValue)
            && (flags.rawValue & modifier.maskBit) != 0
        guard isPressOfTargetKey else { return }

        let now = CACurrentMediaTime()
        if lastModifierKeyCode == keyCode,
           now - lastModifierTapTime <= Self.doubleTapInterval {
            // Двойное нажатие — сброс, чтобы тройное не сработало повторно.
            lastModifierTapTime = 0
            lastModifierKeyCode = -1
            DispatchQueue.main.async { [weak self] in
                self?.manualSwitchSelectedText()
            }
        } else {
            lastModifierTapTime = now
            lastModifierKeyCode = keyCode
        }
    }

    private func manualSwitchSelectedText() {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue else {
            manualSwitchLastWord()
            return
        }

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedRange)

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &currentValue)

        if valueResult == .success, let value = currentValue as? String,
           rangeResult == .success, let rangeVal = selectedRange as? NSRange,
           rangeVal.location != NSNotFound, rangeVal.length > 0 {
            // Есть выделение — конвертируем его через AX.
            let selectedText = (value as NSString).substring(with: rangeVal)
            if let conversion = converter.forceConvert(selectedText) {
                let mutableValue = NSMutableString(string: value)
                mutableValue.replaceCharacters(in: rangeVal, with: conversion.text)
                AXUIElementSetAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, mutableValue)
                inputSources.select(conversion.language)
                onCorrection?(selectedText, conversion.text, conversion.language)
            }
            return
        }

        // Выделения нет — fallback на последнее набранное слово.
        manualSwitchLastWord()
    }

    /// Fallback: переключить последнее набранное слово через backspace + ввод.
    private func manualSwitchLastWord() {
        let word = lastTypedWord
        guard !word.isEmpty, let conversion = converter.forceConvert(word) else { return }
        lastTypedWord = ""
        currentWord = ""
        postBackspaces(word.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.postText(conversion.text)
            self.inputSources.select(conversion.language)
            self.onCorrection?(word, conversion.text, conversion.language)
        }
    }
}
