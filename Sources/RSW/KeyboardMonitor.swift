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

    var onCorrection: ((String, String, KeyboardLanguage) -> Void)?

    private let converter = LayoutConverter()
    private let inputSources = InputSourceController()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapContext: Unmanaged<KeyboardMonitor>?
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
        let retained = Unmanaged.passRetained(self)
        eventTapContext = retained
        let context = retained.toOpaque()
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
        RSWDiagnosticLogger.shared.log("event_tap_started", [
            "enabled": CGEvent.tapIsEnabled(tap: tap)
        ])
        rswDebugLog("[RSW] Event tap включён: \(CGEvent.tapIsEnabled(tap: tap))")
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        eventTapContext?.release()
        eventTapContext = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        RSWDiagnosticLogger.shared.logMemoryIfNeeded()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            RSWDiagnosticLogger.shared.log("event_tap_reenabled", [
                "cgEventType": type.rawValue
            ])
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            RSWDiagnosticLogger.shared.log("synthetic_event_passthrough", [
                "cgEventType": type.rawValue,
                "keyCode": event.getIntegerValueField(.keyboardEventKeycode)
            ])
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let textForLog = type == .keyDown ? eventText(event) : nil

        if focusedAppIsTerminal() {
            RSWDiagnosticLogger.shared.logKeyboardEvent(
                type: type,
                event: event,
                text: textForLog,
                currentWord: currentWord,
                isTerminal: true,
                decision: "terminal_passthrough"
            )
            RSWDiagnosticLogger.shared.logFocusedAX("terminal_passthrough")
            currentWord = ""
            lastTypedWord = ""
            modifierWasDown = false
            return Unmanaged.passUnretained(event)
        }

        let settings = AppSettings.shared
        RSWDiagnosticLogger.shared.logKeyboardEvent(
            type: type,
            event: event,
            text: textForLog,
            currentWord: currentWord,
            isTerminal: false,
            decision: "received"
        )

        if type == .flagsChanged {
            if settings.manualSwitchTrigger == .doubleModifier {
                RSWDiagnosticLogger.shared.logFocusedAX("flags_changed")
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
            if modMask.isEmpty || currentMods.contains(modMask) {
                RSWDiagnosticLogger.shared.log("manual_switch_hotkey", [
                    "keyCode": keyCode,
                    "modifiers": settings.manualSwitchModifiers
                ])
                manualSwitchSelectedText()
                return nil
            }
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            RSWDiagnosticLogger.shared.log("word_reset", [
                "reason": "modifier",
                "currentWordLength": currentWord.count
            ])
            currentWord = ""
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 {
            if !currentWord.isEmpty {
                currentWord.removeLast()
            }
            return Unmanaged.passUnretained(event)
        }

        if settings.isExcludedKey(Int(keyCode)) {
            RSWDiagnosticLogger.shared.log("excluded_key_passthrough", [
                "keyCode": keyCode,
                "currentWordLength": currentWord.count
            ])
            return Unmanaged.passUnretained(event)
        }

        guard let text = eventText(event), !text.isEmpty else {
            RSWDiagnosticLogger.shared.log("word_reset", [
                "reason": "empty_text",
                "currentWordLength": currentWord.count
            ])
            currentWord = ""
            return Unmanaged.passUnretained(event)
        }

        if text.allSatisfy({ $0.isLetter || "`[];',.".contains($0) }) {
            currentWord += text
            lastTypedWord = currentWord
            RSWDiagnosticLogger.shared.log("word_accumulate", [
                "currentWordLength": currentWord.count,
                "textLength": text.count
            ])
            return Unmanaged.passUnretained(event)
        }

        let word = currentWord
        currentWord = ""

        guard isEnabled, word.count >= settings.minWordLength else {
            RSWDiagnosticLogger.shared.log("correction_skipped", [
                "reason": isEnabled ? "short_word" : "disabled",
                "wordLength": word.count,
                "delimiterLength": text.count
            ])
            return Unmanaged.passUnretained(event)
        }

        guard let correction = converter.convert(word) else {
            RSWDiagnosticLogger.shared.log("correction_skipped", [
                "reason": "converter_nil",
                "wordLength": word.count,
                "delimiterLength": text.count
            ])
            return Unmanaged.passUnretained(event)
        }

        RSWDiagnosticLogger.shared.log("correction_accepted", [
            "wordLength": word.count,
            "replacementLength": correction.text.count,
            "delimiterLength": text.count,
            "language": String(describing: correction.language)
        ])
        rswDebugLog("[RSW] АВТО: исправление принято, исходнаяДлина=\(word.count), новаяДлина=\(correction.text.count), язык=\(correction.language)")
        if applyCorrection(word: word, replacement: correction.text, delimiter: text, language: correction.language) {
            onCorrection?(word, correction.text, correction.language)
            return nil
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

    private func applyCorrection(word: String, replacement: String, delimiter: String, language: KeyboardLanguage) -> Bool {
        rswDebugLog("[RSW] ПРИМЕНЕНИЕ: исходнаяДлина=\(word.count), новаяДлина=\(replacement.count)")
        RSWDiagnosticLogger.shared.logFocusedAX("apply_correction")

        if focusedAppIsTerminal() {
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: терминал пропущен")
            RSWDiagnosticLogger.shared.log("correction_failed", [
                "reason": "terminal_excluded",
                "wordLength": word.count,
                "replacementLength": replacement.count,
                "delimiterLength": delimiter.count,
                "language": String(describing: language)
            ])
            return false
        }

        if replaceWordBeforeCursorViaAX(
            word: word,
            replacement: replacement,
            delimiter: delimiter,
            insertDelimiterIfMissing: true
        ) {
            RSWDiagnosticLogger.shared.log("correction_applied", [
                "path": "ax",
                "wordLength": word.count,
                "replacementLength": replacement.count,
                "delimiterLength": delimiter.count,
                "language": String(describing: language)
            ])
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: AX успешно")
            inputSources.select(language)
            return true
        }

        rswDebugLog("[RSW] ПРИМЕНЕНИЕ: AX не сработал, автоисправление отменено")
        RSWDiagnosticLogger.shared.log("correction_failed", [
            "reason": "ax_unavailable",
            "wordLength": word.count,
            "replacementLength": replacement.count,
            "delimiterLength": delimiter.count,
            "language": String(describing: language)
        ])
        return false
    }

    private func replaceWordBeforeCursorViaAX(
        word: String,
        replacement: String,
        delimiter: String,
        insertDelimiterIfMissing: Bool
    ) -> Bool {
        guard let focused = focusedAXElement() else {
            return false
        }

        var currentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue) == .success,
              let value = currentValue as? String else {
            rswDebugLog("[RSW] AX: не удалось прочитать значение")
            return false
        }

        guard let selectedRange = selectedTextRange(in: focused) else {
            rswDebugLog("[RSW] AX: не удалось прочитать диапазон выделения")
            return false
        }

        let nsValue = value as NSString
        let valueLength = nsValue.length
        let wordLength = (word as NSString).length
        let delimiterLength = (delimiter as NSString).length

        guard selectedRange.location != NSNotFound,
              selectedRange.location <= valueLength,
              selectedRange.length == 0 else {
            rswDebugLog("[RSW] AX: некорректный диапазон курсора, длинаЗначения=\(valueLength), курсор=\(selectedRange.location), выделение=\(selectedRange.length)")
            return false
        }

        let delimiterAlreadyInserted =
            delimiterLength > 0 &&
            selectedRange.location >= delimiterLength &&
            nsValue.substring(
                with: NSRange(location: selectedRange.location - delimiterLength, length: delimiterLength)
            ) == delimiter

        var wordEnd = delimiterAlreadyInserted
            ? selectedRange.location - delimiterLength
            : selectedRange.location

        if !delimiterAlreadyInserted && delimiterLength == 0 {
            while wordEnd > 0 {
                let ch = nsValue.character(at: wordEnd - 1)
                guard let scalar = Unicode.Scalar(ch) else { break }
                if CharacterSet.whitespaces.contains(scalar) {
                    wordEnd -= 1
                } else {
                    break
                }
            }
        }

        guard wordEnd >= wordLength else {
            rswDebugLog("[RSW] AX: слово перед курсором короче ожидаемого, конецСлова=\(wordEnd), длинаСлова=\(wordLength)")
            return false
        }

        let actualReplacement = replacement + (insertDelimiterIfMissing && !delimiterAlreadyInserted ? delimiter : "")
        let replaceRange = NSRange(location: wordEnd - wordLength, length: wordLength)
        let mutable = NSMutableString(string: value)
        mutable.replaceCharacters(in: replaceRange, with: actualReplacement)

        rswDebugLog("[RSW] AX: замена слова перед курсором, длинаЗначения=\(valueLength), диапазон={\(replaceRange.location), \(replaceRange.length)}, новаяДлина=\(actualReplacement.count), разделительУжеЕсть=\(delimiterAlreadyInserted)")

        let setResult = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, mutable)
        guard setResult == .success else {
            RSWDiagnosticLogger.shared.log("ax_set_failed", [
                "code": setResult.rawValue,
                "valueLength": valueLength,
                "rangeLocation": replaceRange.location,
                "rangeLength": replaceRange.length
            ])
            rswDebugLog("[RSW] AX: запись не удалась, код=\(setResult.rawValue)")
            return false
        }

        let caretRange = NSRange(
            location: replaceRange.location + (actualReplacement as NSString).length + (delimiterAlreadyInserted ? delimiterLength : 0),
            length: 0
        )
        setSelectedTextRange(caretRange, in: focused)
        return true
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

            rswDebugLog("[RSW] МОДИФИКАТОР: клавиша=\(keyCode), прошло=\(String(format: "%.3f", elapsed)), таЖеГруппа=\(sameKey)")

            if sameKey,
               elapsed <= Self.doubleTapInterval {
                lastModifierTapTime = 0
                lastModifierKeyCode = -1
                rswDebugLog("[RSW] МОДИФИКАТОР: двойное нажатие → ручное переключение")
                manualSwitchSelectedText()
            } else {
                lastModifierTapTime = now
                lastModifierKeyCode = keyCode
            }
        }

        modifierWasDown = isDown
    }

    // MARK: - Manual switch (AX-only)

    private func manualSwitchSelectedText() {
        rswDebugLog("[RSW] РУЧНОЕ: попытка")
        RSWDiagnosticLogger.shared.logFocusedAX("manual_switch")

        guard let focused = focusedAXElement() else {
            RSWDiagnosticLogger.shared.log("manual_switch_failed", [
                "reason": "no_focused_ax"
            ])
            manualSwitchLastWord()
            return
        }

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue)

        if valueResult == .success, let value = currentValue as? String,
           let rangeVal = selectedTextRange(in: focused),
           rangeVal.location != NSNotFound, rangeVal.length > 0,
           NSMaxRange(rangeVal) <= (value as NSString).length {
            let selectedText = (value as NSString).substring(with: rangeVal)
            rswDebugLog("[RSW] РУЧНОЕ: длинаВыделения=\(selectedText.count)")
            if let conversion = converter.forceConvert(selectedText) {
                RSWDiagnosticLogger.shared.log("manual_switch_selected", [
                    "selectedLength": selectedText.count,
                    "replacementLength": conversion.text.count,
                    "language": String(describing: conversion.language)
                ])
                rswDebugLog("[RSW] РУЧНОЕ: новаяДлина=\(conversion.text.count), язык=\(conversion.language)")
                let mutableValue = NSMutableString(string: value)
                mutableValue.replaceCharacters(in: rangeVal, with: conversion.text)
                let setResult = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, mutableValue)
                if setResult == .success {
                    RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                        "path": "ax",
                        "selectedLength": selectedText.count,
                        "replacementLength": conversion.text.count
                    ])
                    setSelectedTextRange(
                        NSRange(location: rangeVal.location, length: (conversion.text as NSString).length),
                        in: focused
                    )
                    inputSources.select(conversion.language)
                    onCorrection?(selectedText, conversion.text, conversion.language)
                    return
                }

                rswDebugLog("[RSW] РУЧНОЕ: запись выделения не удалась, код=\(setResult.rawValue)")
                RSWDiagnosticLogger.shared.log("manual_switch_failed", [
                    "reason": "ax_set_failed",
                    "code": setResult.rawValue
                ])
            } else {
                RSWDiagnosticLogger.shared.log("manual_switch_failed", [
                    "reason": "no_conversion",
                    "selectedLength": selectedText.count
                ])
            }
            return
        }

        RSWDiagnosticLogger.shared.log("manual_switch_failed", [
            "reason": "no_selection"
        ])
        rswDebugLog("[RSW] РУЧНОЕ: нет выделения, пробую последнее слово")
        manualSwitchLastWord()
    }

    private func manualSwitchLastWord() {
        let word = lastTypedWord
        rswDebugLog("[RSW] РУЧНОЕ последнее слово: длина=\(word.count)")
        guard !word.isEmpty, let conversion = converter.forceConvert(word) else {
            RSWDiagnosticLogger.shared.log("manual_switch_failed", [
                "reason": "empty_or_no_conversion",
                "wordLength": word.count
            ])
            return
        }
        currentWord = ""

        rswDebugLog("[RSW] РУЧНОЕ: новаяДлина=\(conversion.text.count), язык=\(conversion.language)")
        if replaceWordBeforeCursorViaAX(
            word: word,
            replacement: conversion.text,
            delimiter: "",
            insertDelimiterIfMissing: false
        ) {
            RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                "path": "last_word_ax",
                "wordLength": word.count,
                "replacementLength": conversion.text.count,
                "language": String(describing: conversion.language)
            ])
            lastTypedWord = conversion.text
            inputSources.select(conversion.language)
            onCorrection?(word, conversion.text, conversion.language)
            return
        }

        RSWDiagnosticLogger.shared.log("manual_switch_failed", [
            "reason": "ax_unavailable",
            "wordLength": word.count
        ])
    }

    private func focusedAppIsTerminal() -> Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    private func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            rswDebugLog("[RSW] AX: нет активного элемента")
            return nil
        }
        return (focused as! AXUIElement)
    }

    private func selectedTextRange(in element: AXUIElement) -> NSRange? {
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        let axRange = rangeValue as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func selectedText(in element: AXUIElement) -> String? {
        var selectedTextValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextValue) == .success,
              let selectedText = selectedTextValue as? String,
              !selectedText.isEmpty else {
            return nil
        }
        return selectedText
    }

    private func focusedValueString(in element: AXUIElement) -> String? {
        var currentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue) == .success,
              let value = currentValue as? String else {
            return nil
        }
        return value
    }

    @discardableResult
    private func setSelectedTextRange(_ range: NSRange, in element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
