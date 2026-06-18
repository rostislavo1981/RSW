import AppKit
import SwitcherCore

final class KeyboardMonitor {
    private static let syntheticEventMarker: Int64 = 0x54494E59
    private static let deleteKeyCode: CGKeyCode = 51
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
                DispatchQueue.main.async { [weak self] in
                    self?.manualSwitchSelectedText()
                }
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
                if focusedAppPrefersBufferedReplacement() {
                    return nil
                }
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

        if focusedAppPrefersBufferedReplacement() {
            return handleBufferedTerminalInput(text: text, settings: settings)
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
        if focusedAppPrefersSyntheticReplacement() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard self?.applyTerminalCorrectionAfterDelimiter(
                    word: word,
                    replacement: correction.text,
                    delimiter: text,
                    language: correction.language
                ) == true else {
                    return
                }
                self?.onCorrection?(word, correction.text, correction.language)
            }
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.async { [weak self] in
            self?.applyCorrection(word: word, replacement: correction.text, delimiter: text, language: correction.language)
            self?.onCorrection?(word, correction.text, correction.language)
        }
        return nil
    }

    private func handleBufferedTerminalInput(text: String, settings: AppSettings) -> Unmanaged<CGEvent>? {
        if text.allSatisfy({ $0.isLetter || "`[];',.".contains($0) }) {
            currentWord += text
            lastTypedWord = currentWord
            return nil
        }

        let word = currentWord
        currentWord = ""

        guard !word.isEmpty else {
            _ = pasteTextToFrontmostApp(text) || postText(text)
            return nil
        }

        if isEnabled,
           word.count >= settings.minWordLength,
           let correction = converter.convert(word) {
            let inserted = pasteTextToFrontmostApp(correction.text + text)
                || postText(correction.text + text)
            if inserted {
                inputSources.select(correction.language)
                onCorrection?(word, correction.text, correction.language)
            }
            return nil
        }

        _ = pasteTextToFrontmostApp(word + text) || postText(word + text)
        return nil
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
        rswDebugLog("[RSW] ПРИМЕНЕНИЕ: исходнаяДлина=\(word.count), новаяДлина=\(replacement.count)")
        RSWDiagnosticLogger.shared.logFocusedAX("apply_correction")

        if focusedAppPrefersSyntheticReplacement(),
           replaceWordViaTerminalPaste(word: word, replacement: replacement + delimiter) {
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: pasteboard-замена для терминала отправлена")
            inputSources.select(language)
            return
        }

        if focusedAppPrefersSyntheticReplacement() {
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: терминальная замена не подтверждена, возвращаю разделитель")
            postText(delimiter)
            inputSources.select(language)
            return
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
            return
        }

        rswDebugLog("[RSW] ПРИМЕНЕНИЕ: AX не сработал")
        if replaceWordViaSyntheticEvents(wordLength: word.count, replacement: replacement + delimiter) {
            RSWDiagnosticLogger.shared.log("correction_applied", [
                "path": "synthetic",
                "wordLength": word.count,
                "replacementLength": replacement.count,
                "delimiterLength": delimiter.count,
                "language": String(describing: language)
            ])
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: синтетическая замена отправлена")
            inputSources.select(language)
            return
        }

        RSWDiagnosticLogger.shared.log("correction_failed", [
            "wordLength": word.count,
            "replacementLength": replacement.count,
            "delimiterLength": delimiter.count,
            "language": String(describing: language)
        ])
        postText(delimiter)
        inputSources.select(language)
    }

    private func applyTerminalCorrectionAfterDelimiter(
        word: String,
        replacement: String,
        delimiter: String,
        language: KeyboardLanguage
    ) -> Bool {
        rswDebugLog("[RSW] TERMINAL: попытка замены после доставленного разделителя")
        guard replaceTerminalWordBeforeDelimiter(word: word, replacement: replacement, delimiter: delimiter) else {
            rswDebugLog("[RSW] TERMINAL: замена после разделителя не подтверждена")
            return false
        }
        inputSources.select(language)
        return true
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
        rswDebugLog("[RSW] РУЧНОЕ: попытка")
        RSWDiagnosticLogger.shared.logFocusedAX("manual_switch")

        guard let focused = focusedAXElement() else {
            RSWDiagnosticLogger.shared.log("manual_switch_fallback", [
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
                } else {
                    rswDebugLog("[RSW] РУЧНОЕ: запись выделения не удалась, код=\(setResult.rawValue)")
                }

                if replaceCurrentSelectionViaPaste(replacement: conversion.text) {
                    RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                        "path": "pasteboard",
                        "selectedLength": selectedText.count,
                        "replacementLength": conversion.text.count
                    ])
                    inputSources.select(conversion.language)
                    onCorrection?(selectedText, conversion.text, conversion.language)
                    return
                }
            }
            return
        }

        if let selectedText = selectedText(in: focused),
           let conversion = converter.forceConvert(selectedText),
           replaceCurrentSelectionViaPaste(replacement: conversion.text) {
            RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                "path": "selected_text_pasteboard",
                "selectedLength": selectedText.count,
                "replacementLength": conversion.text.count,
                "language": String(describing: conversion.language)
            ])
            inputSources.select(conversion.language)
            onCorrection?(selectedText, conversion.text, conversion.language)
            return
        }

        RSWDiagnosticLogger.shared.log("manual_switch_fallback", [
            "reason": "no_selection"
        ])
        rswDebugLog("[RSW] РУЧНОЕ: нет выделения, пробую последнее слово")
        manualSwitchLastWord()
    }

    private func manualSwitchLastWord() {
        let word = lastTypedWord
        rswDebugLog("[RSW] РУЧНОЕ последнее слово: длина=\(word.count)")
        guard !word.isEmpty, let conversion = converter.forceConvert(word) else {
            RSWDiagnosticLogger.shared.log("manual_switch_last_word_skipped", [
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
        } else if focusedAppPrefersSyntheticReplacement(),
                  replaceWordViaTerminalPaste(word: word, replacement: conversion.text) {
            RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                "path": "last_word_terminal_pasteboard",
                "wordLength": word.count,
                "replacementLength": conversion.text.count,
                "language": String(describing: conversion.language)
            ])
            lastTypedWord = conversion.text
            inputSources.select(conversion.language)
            onCorrection?(word, conversion.text, conversion.language)
        } else if focusedAppPrefersSyntheticReplacement() {
            rswDebugLog("[RSW] РУЧНОЕ: терминальная замена последнего слова не подтверждена")
        } else if replaceWordViaSyntheticEvents(wordLength: word.count, replacement: conversion.text) {
            RSWDiagnosticLogger.shared.log("manual_switch_applied", [
                "path": "last_word_synthetic",
                "wordLength": word.count,
                "replacementLength": conversion.text.count,
                "language": String(describing: conversion.language)
            ])
            lastTypedWord = conversion.text
            inputSources.select(conversion.language)
            onCorrection?(word, conversion.text, conversion.language)
        }
    }

    private func replaceWordViaSyntheticEvents(wordLength: Int, replacement: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        for _ in 0..<wordLength {
            postKey(keyCode: Self.deleteKeyCode, keyDown: true, source: source)
            postKey(keyCode: Self.deleteKeyCode, keyDown: false, source: source)
        }

        postText(replacement, source: source)
        return true
    }

    private struct PasteboardSnapshot {
        let changeCount: Int
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private func replaceWordViaTerminalPaste(word: String, replacement: String) -> Bool {
        guard selectWordBeforeCursorViaAX(word: word) else {
            rswDebugLog("[RSW] TERMINAL: не удалось выделить слово перед курсором")
            return false
        }

        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
        let payloadChangeCount = pasteboard.changeCount

        let pasted = performPasteMenuActionInFrontmostApp()
        if pasted {
            restorePasteboard(snapshot, to: pasteboard, expectedChangeCount: payloadChangeCount, delay: 0.5)
        } else {
            restorePasteboard(snapshot, to: pasteboard, expectedChangeCount: payloadChangeCount, delay: 0)
        }
        return pasted
    }

    private func replaceTerminalWordBeforeDelimiter(
        word: String,
        replacement: String,
        delimiter: String
    ) -> Bool {
        guard selectWordBeforeCursorViaAX(word: word, delimiter: delimiter) else {
            return false
        }
        return replaceCurrentSelectionViaPaste(replacement: replacement)
    }

    private func selectWordBeforeCursorViaAX(word: String) -> Bool {
        selectWordBeforeCursorViaAX(word: word, delimiter: "")
    }

    private func selectWordBeforeCursorViaAX(word: String, delimiter: String) -> Bool {
        guard let focused = focusedAXElement(),
              let selectedRange = selectedTextRange(in: focused),
              selectedRange.location != NSNotFound,
              selectedRange.length == 0 else {
            return false
        }

        let wordLength = (word as NSString).length
        let delimiterLength = (delimiter as NSString).length
        guard selectedRange.location >= wordLength + delimiterLength else { return false }

        if delimiterLength > 0,
           let value = focusedValueString(in: focused) {
            let nsValue = value as NSString
            let delimiterRange = NSRange(location: selectedRange.location - delimiterLength, length: delimiterLength)
            guard NSMaxRange(delimiterRange) <= nsValue.length,
                  nsValue.substring(with: delimiterRange) == delimiter else {
                return false
            }
        }

        let range = NSRange(
            location: selectedRange.location - delimiterLength - wordLength,
            length: wordLength
        )
        guard setSelectedTextRange(range, in: focused) else { return false }

        guard let selectedText = selectedText(in: focused),
              selectedText == word else {
            rswDebugLog("[RSW] TERMINAL: AX подтвердил range, но selectedText не совпал со словом")
            setSelectedTextRange(NSRange(location: selectedRange.location, length: 0), in: focused)
            return false
        }

        return true
    }

    private func replaceCurrentSelectionViaPaste(replacement: String) -> Bool {
        pasteTextToFrontmostApp(replacement)
    }

    private func pasteTextToFrontmostApp(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let snapshot = snapshotPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let payloadChangeCount = pasteboard.changeCount

        let pasted = performPasteMenuActionInFrontmostApp()
        if pasted {
            restorePasteboard(snapshot, to: pasteboard, expectedChangeCount: payloadChangeCount, delay: 0.5)
        } else {
            restorePasteboard(snapshot, to: pasteboard, expectedChangeCount: payloadChangeCount, delay: 0)
        }
        return pasted
    }

    private func snapshotPasteboard(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return dataByType
        } ?? []
        return PasteboardSnapshot(changeCount: pasteboard.changeCount, items: items)
    }

    private func restorePasteboard(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        expectedChangeCount: Int,
        delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
            let restoredItems = snapshot.items.map { itemData in
                let item = NSPasteboardItem()
                for (type, data) in itemData {
                    item.setData(data, forType: type)
                }
                return item
            }
            pasteboard.writeObjects(restoredItems)
        }
    }

    private func performPasteMenuActionInFrontmostApp() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var menuBarValue: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBar = menuBarValue,
              CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
              let pasteItem = findPasteMenuItem(in: menuBar as! AXUIElement) else {
            return false
        }

        return AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success
    }

    private func findPasteMenuItem(in element: AXUIElement) -> AXUIElement? {
        if menuItemIsPaste(element) {
            return element
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let result = findPasteMenuItem(in: child) {
                return result
            }
        }
        return nil
    }

    private func menuItemIsPaste(_ element: AXUIElement) -> Bool {
        var cmdCharValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXMenuItemCmdCharAttribute as CFString, &cmdCharValue) == .success,
              let cmdChar = cmdCharValue as? String,
              cmdChar.lowercased() == "v" else {
            return false
        }
        return true
    }

    private func focusedAppPrefersSyntheticReplacement() -> Bool {
        focusedAppIsTerminal()
    }

    private func focusedAppIsTerminal() -> Bool {
        guard let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    private func focusedAppPrefersBufferedReplacement() -> Bool {
        focusedAppPrefersSyntheticReplacement()
    }

    private func postKey(
        keyCode: CGKeyCode,
        keyDown: Bool,
        source: CGEventSource,
        flags: CGEventFlags = []
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            return
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func postText(_ text: String, source: CGEventSource) -> Bool {
        var posted = false
        for scalar in text.unicodeScalars {
            guard scalar.value <= UInt32(UInt16.max) else { continue }
            var codeUnit = UniChar(scalar.value)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }
            keyDown.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            keyUp.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            posted = true
        }
        return posted
    }

    @discardableResult
    private func postText(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        return postText(text, source: source)
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
