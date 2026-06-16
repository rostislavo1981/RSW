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
    private var lastTypedWord = ""

    private var lastModifierTapTime: CFTimeInterval = 0
    private var lastModifierKeyCode: Int64 = -1
    private var modifierWasDown = false
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
        fputs("[RSW] Event tap enabled: \(CGEvent.tapIsEnabled(tap: tap))\n", stderr)
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

        if type == .flagsChanged {
            if settings.manualSwitchTrigger == .doubleModifier {
                handleModifierDoubleTap(keyCode: keyCode, flags: event.flags, settings: settings)
            }
            return Unmanaged.passUnretained(event)
        }

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
            if !modMask.isEmpty && currentMods.contains(modMask) {
                DispatchQueue.main.async { [weak self] in
                    self?.manualSwitchSelectedText()
                }
                return nil
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

        fputs("[RSW] AUTO: '\(word)' → '\(correction.text)' (\(correction.language))\n", stderr)
        DispatchQueue.main.async { [weak self] in
            self?.applyCorrection(word: word, replacement: correction.text, delimiter: text, language: correction.language)
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

    // MARK: - Auto-correction via AX (position-based)

    private func applyCorrection(word: String, replacement: String, delimiter: String, language: KeyboardLanguage) {
        fputs("[RSW] APPLY: '\(word)' → '\(replacement)'\n", stderr)

        if replaceTailViaAX(tailLength: word.count + delimiter.count, replacement: replacement + delimiter) {
            fputs("[RSW] APPLY: AX OK\n", stderr)
            inputSources.select(language)
            return
        }

        fputs("[RSW] APPLY: AX failed\n", stderr)
        inputSources.select(language)
    }

    private func replaceTailViaAX(tailLength: Int, replacement: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue else {
            fputs("[RSW] AX: no focused element\n", stderr)
            return false
        }

        var currentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &currentValue) == .success,
              let value = currentValue as? String else {
            fputs("[RSW] AX: cannot read value\n", stderr)
            return false
        }

        fputs("[RSW] AX value (\(value.count) chars): '\(value)'\n", stderr)

        guard value.count >= tailLength else {
            fputs("[RSW] AX: value too short (\(value.count) < \(tailLength))\n", stderr)
            return false
        }

        let endIndex = value.index(value.endIndex, offsetBy: -tailLength)
        let prefix = String(value[..<endIndex])
        let newValue = prefix + replacement

        fputs("[RSW] AX: replacing tail \(tailLength) chars → '\(replacement)'\n", stderr)

        let mutable = NSMutableString(string: newValue)
        let setResult = AXUIElementSetAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, mutable)
        fputs("[RSW] AX set: \(setResult.rawValue), new value: '\(newValue)'\n", stderr)
        return setResult == .success
    }

    // MARK: - Double-Option manual switch

    private func handleModifierDoubleTap(keyCode: Int64, flags: CGEventFlags, settings: AppSettings) {
        guard let modifier = ManualSwitchModifier(rawValue: settings.manualSwitchModifierKey) else {
            return
        }

        let isDown = (flags.rawValue & modifier.maskBit) != 0

        if isDown && !modifierWasDown {
            let now = CACurrentMediaTime()
            let elapsed = now - lastModifierTapTime
            let sameKey = modifier.keyCodes.contains(Int(keyCode)) && modifier.keyCodes.contains(Int(lastModifierKeyCode))

            fputs("[RSW] MOD: key=\(keyCode) elapsed=\(String(format: "%.3f", elapsed)) sameKey=\(sameKey)\n", stderr)

            if sameKey,
               elapsed <= Self.doubleTapInterval {
                lastModifierTapTime = 0
                lastModifierKeyCode = -1
                fputs("[RSW] MOD: DOUBLE TAP → manualSwitch\n", stderr)
                DispatchQueue.main.async { [weak self] in
                    self?.manualSwitchSelectedText()
                }
            } else {
                lastModifierTapTime = now
                lastModifierKeyCode = keyCode
            }
        }

        modifierWasDown = isDown
    }

    // MARK: - Manual switch

    private func manualSwitchSelectedText() {
        fputs("[RSW] MANUAL: trying\n", stderr)

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue else {
            fputs("[RSW] MANUAL: no focused element\n", stderr)
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
            let selectedText = (value as NSString).substring(with: rangeVal)
            fputs("[RSW] MANUAL: selected='\(selectedText)'\n", stderr)
            if let conversion = converter.forceConvert(selectedText) {
                fputs("[RSW] MANUAL: '\(selectedText)' → '\(conversion.text)'\n", stderr)
                let mutableValue = NSMutableString(string: value)
                mutableValue.replaceCharacters(in: rangeVal, with: conversion.text)
                AXUIElementSetAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, mutableValue)
                inputSources.select(conversion.language)
                onCorrection?(selectedText, conversion.text, conversion.language)
            }
            return
        }

        fputs("[RSW] MANUAL: no selection, trying lastWord\n", stderr)
        manualSwitchLastWord()
    }

    private func manualSwitchLastWord() {
        let word = lastTypedWord
        fputs("[RSW] MANUAL lastWord: '\(word)'\n", stderr)
        guard !word.isEmpty, let conversion = converter.forceConvert(word) else { return }
        lastTypedWord = ""
        currentWord = ""

        fputs("[RSW] MANUAL: '\(word)' → '\(conversion.text)'\n", stderr)
        if replaceTailViaAX(tailLength: word.count, replacement: conversion.text) {
            inputSources.select(conversion.language)
            onCorrection?(word, conversion.text, conversion.language)
        }
    }
}
