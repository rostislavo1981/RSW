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

    var isEnabled = true

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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
            fputs("[rswitcher] WARNING: tap disabled, re-enabling\n", stderr)
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let settings = AppSettings.shared
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if settings.manualSwitchKeyCode >= 0 && keyCode == settings.manualSwitchKeyCode {
            let flags = event.flags
            var currentMods: NSEvent.ModifierFlags = []
            if flags.contains(.maskCommand) { currentMods.insert(.command) }
            if flags.contains(.maskControl) { currentMods.insert(.control) }
            if flags.contains(.maskAlternate) { currentMods.insert(.option) }
            if flags.contains(.maskShift) { currentMods.insert(.shift) }

            let modMask = NSEvent.ModifierFlags(rawValue: UInt(settings.manualSwitchModifiers))
            if modMask.isEmpty || currentMods.contains(modMask) {
                DispatchQueue.main.async { [weak self] in
                    self?.manualSwitchSelectedText()
                }
                return Unmanaged.passUnretained(event)
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
            return Unmanaged.passUnretained(event)
        }

        let word = currentWord
        currentWord = ""

        guard isEnabled, word.count >= settings.minWordLength else {
            return Unmanaged.passUnretained(event)
        }

        fputs("[rswitcher] word='\(word)' delim='\(text)'\n", stderr)
        guard let correction = converter.convert(word) else {
            return Unmanaged.passUnretained(event)
        }

        fputs("[rswitcher] CORRECT: '\(word)' → '\(correction.text)' (\(correction.language))\n", stderr)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.replaceViaAX(word: word, replacement: correction.text, delimiter: text)
            self?.inputSources.select(correction.language)
            self?.onCorrection?(word, correction.text, correction.language)
        }
        return Unmanaged.passUnretained(event)
    }

    private func manualSwitchSelectedText() {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focused = focusedValue as! AXUIElement? else { return }

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedRange)

        var currentValue: AnyObject?
        let valResult = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue)
        guard valResult == .success, let value = currentValue as? String else { return }

        if rangeResult == .success, let rangeVal = selectedRange as? NSRange, rangeVal.location != NSNotFound, rangeVal.length > 0 {
            let selectedText = (value as NSString).substring(with: rangeVal)
            if let conversion = converter.forceConvert(selectedText) {
                let mutableValue = NSMutableString(string: value)
                mutableValue.replaceCharacters(in: rangeVal, with: conversion.text)
                AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, mutableValue)
                inputSources.select(conversion.language)
            }
        } else {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trimmed.split(separator: " ")
            if let lastWord = words.last, let conversion = converter.forceConvert(String(lastWord)) {
                let mutableValue = NSMutableString(string: value)
                let searchRange = NSRange(location: 0, length: mutableValue.length)
                let foundRange = mutableValue.range(of: String(lastWord), options: .backwards, range: searchRange)
                if foundRange.location != NSNotFound {
                    mutableValue.replaceCharacters(in: foundRange, with: conversion.text)
                    AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, mutableValue)
                    inputSources.select(conversion.language)
                }
            }
        }
    }

    private func eventText(_ event: CGEvent) -> String? {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var buffer = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(
            maxStringLength: length,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        return String(utf16CodeUnits: buffer, count: length)
    }

    private func replaceViaAX(word: String, replacement: String, delimiter: String) {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard result == .success, let focused = focusedValue else {
            fputs("[rswitcher] AX: no focused element\n", stderr)
            return
        }

        var currentValue: AnyObject?
        let valResult = AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, &currentValue)
        guard valResult == .success, let value = currentValue as? String else {
            fputs("[rswitcher] AX: cannot read value\n", stderr)
            return
        }

        fputs("[rswitcher] AX value: '\(value)'\n", stderr)

        let target = word + delimiter
        guard let range = value.range(of: target) else {
            fputs("[rswitcher] AX: target '\(target)' not found in value\n", stderr)
            return
        }

        let newValue = value.replacingCharacters(in: range, with: replacement + delimiter)
        fputs("[rswitcher] AX new value: '\(newValue)'\n", stderr)

        let setResult = AXUIElementSetAttributeValue(focused as! AXUIElement, kAXValueAttribute as CFString, newValue as CFTypeRef)
        if setResult != .success {
            fputs("[rswitcher] AX: setValue failed (\(setResult.rawValue))\n", stderr)
        }
    }
}
