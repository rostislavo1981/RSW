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
    /// Опциональный policy для тонкого контроля над allow/deny. Если `nil`
    /// (по умолчанию для обратной совместимости), действует прежнее правило:
    /// разрешено всё, кроме терминалов. После Phase 4 completion
    /// `AppDelegate` инжектит сюда `DefaultAppPolicy` с реальной логикой.
    private let appPolicy: AppPolicy?

    init(appPolicy: AppPolicy? = nil) {
        self.appPolicy = appPolicy
    }
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventTapContext: Unmanaged<KeyboardMonitor>?
    /// Phase 2 wire-in: WordBuffer теперь — единственный владелец состояния
    /// текущего слова. `currentWord` доступен через `wordBuffer.currentWord`,
    /// `lastTypedWord` — отдельное String-свойство, т.к. по семантике
    /// относится к уже отправленному (а не буферизованному) слову.
    private var wordBuffer = WordBuffer()
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
        let tap: CFMachPort
        do {
            // Use a temporary local context for the tapCreate call.
            // If tapCreate fails we throw away the Unmanaged reference
            // to avoid leaking it (the previous implementation called
            // Unmanaged.passRetained(self) before the failure check,
            // which leaked KeyboardMonitor on every start() failure).
            let probe = Unmanaged.passRetained(self)
            guard let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: probe.toOpaque()
            ) else {
                probe.release()
                return false
            }
            tap = created
            eventTapContext = probe
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
                currentWord: wordBuffer.currentWord,
                isTerminal: true,
                decision: "terminal_passthrough"
            )
            RSWDiagnosticLogger.shared.logFocusedAX("terminal_passthrough")
            wordBuffer.reset()
            lastTypedWord = ""
            modifierWasDown = false
            return Unmanaged.passUnretained(event)
        }

        let settings = AppSettings.shared
        RSWDiagnosticLogger.shared.logKeyboardEvent(
            type: type,
            event: event,
            text: textForLog,
            currentWord: wordBuffer.currentWord,
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
                "currentWordLength": wordBuffer.currentWord.count
            ])
            wordBuffer.reset()
            return Unmanaged.passUnretained(event)
        }

        if keyCode == 51 {
            wordBuffer.removeLast()
            return Unmanaged.passUnretained(event)
        }

        if settings.isExcludedKey(Int(keyCode)) {
            RSWDiagnosticLogger.shared.log("excluded_key_passthrough", [
                "keyCode": keyCode,
                "currentWordLength": wordBuffer.currentWord.count
            ])
            return Unmanaged.passUnretained(event)
        }

        guard let text = eventText(event), !text.isEmpty else {
            RSWDiagnosticLogger.shared.log("word_reset", [
                "reason": "empty_text",
                "currentWordLength": wordBuffer.currentWord.count
            ])
            wordBuffer.reset()
            return Unmanaged.passUnretained(event)
        }

        if text.allSatisfy({ $0.isLetter || "`[];',.".contains($0) }) {
            for ch in text {
                wordBuffer.append(ch)
            }
            lastTypedWord = wordBuffer.currentWord
            RSWDiagnosticLogger.shared.log("word_accumulate", [
                "currentWordLength": wordBuffer.currentWord.count,
                "textLength": text.count
            ])
            return Unmanaged.passUnretained(event)
        }

        let word = wordBuffer.currentWord
        wordBuffer.reset()

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

        // Phase 4 wire-in: если policy задана, проверяем allow/deny по bundleID.
        // Если policy не инжектирована (обратная совместимость), пропускаем
        // проверку — действует прежнее поведение «разрешено всё, кроме терминалов».
        if let appPolicy = self.appPolicy,
           let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !appPolicy.shouldAllowAutomaticReplacement(for: bundleID) {
            rswDebugLog("[RSW] ПРИМЕНЕНИЕ: отклонено policy, bundleID=\(bundleID)")
            RSWDiagnosticLogger.shared.log("correction_failed", [
                "reason": "policy_denied",
                "bundleID": bundleID,
                "wordLength": word.count,
                "replacementLength": replacement.count,
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
            rswDebugLog("[RSW] AX: нет активного элемента")
            return false
        }

        // ── Логируем AX-роль и bundleID для диагностики ─────────────────
        var roleValue: AnyObject?
        let roleResult = AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleResult == .success) ? (roleValue as? String ?? "nil") : "error:\(roleResult.rawValue)"
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        rswDebugLog("[RSW] AX: роль=\(role), bundleID=\(bundleID)")

        // ── Путь 1: kAXValueAttribute (стандартный текстовый элемент) ──────
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &currentValue)
        if valueResult == .success, let value = currentValue as? String {
            rswDebugLog("[RSW] AX: kAXValueAttribute прочитан, длина=\(value.count)")
            return replaceViaValueAttribute(
                focused: focused,
                word: word,
                replacement: replacement,
                delimiter: delimiter,
                insertDelimiterIfMissing: insertDelimiterIfMissing,
                currentValue: value
            )
        }

        rswDebugLog("[RSW] AX: kAXValueAttribute недоступен (код=\(valueResult.rawValue)), пробуем kAXSelectedText")

        // ── Путь 2: kAXSelectedText (Excel, Google Docs и прочие нестандартные) ─
        // В некоторых приложениях (Excel, веб-формы) kAXValueAttribute недоступен,
        // но kAXSelectedTextAttribute работает. Стратегия:
        //   1. Выделяем слово перед курсором (setSelectedTextRange)
        //   2. Читаем выделенный текст как подтверждение
        //   3. Заменяем выделение через setSelectedTextRange + typing
        return replaceViaSelectedText(
            focused: focused,
            word: word,
            replacement: replacement,
            delimiter: delimiter,
            insertDelimiterIfMissing: insertDelimiterIfMissing
        )
    }

    // MARK: - Путь 1: замена через kAXValueAttribute

    private func replaceViaValueAttribute(
        focused: AXUIElement,
        word: String,
        replacement: String,
        delimiter: String,
        insertDelimiterIfMissing: Bool,
        currentValue: String
    ) -> Bool {
        guard let selectedRange = selectedTextRange(in: focused) else {
            rswDebugLog("[RSW] AX: не удалось прочитать диапазон выделения")
            return false
        }

        let nsValue = currentValue as NSString
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

        // ─── Guard: подстрока перед курсором должна совпадать с `word` ──────
        let actualRange = NSRange(location: wordEnd - wordLength, length: wordLength)
        let actualSubstring = nsValue.substring(with: actualRange)
        guard actualSubstring.caseInsensitiveCompare(word) == .orderedSame else {
            rswDebugLog("[RSW] AX: подстрока перед курсором не совпала с ожидаемой, ожидалось=\(word), фактически=\(actualSubstring)")
            return false
        }

        let actualReplacement = replacement + (insertDelimiterIfMissing && !delimiterAlreadyInserted ? delimiter : "")
        let replaceRange = NSRange(location: wordEnd - wordLength, length: wordLength)
        let mutable = NSMutableString(string: currentValue)
        mutable.replaceCharacters(in: replaceRange, with: actualReplacement)

        rswDebugLog("[RSW] AX: замена через kAXValue, диапазон={\(replaceRange.location), \(replaceRange.length)}, новаяДлина=\(actualReplacement.count), разделительУжеЕсть=\(delimiterAlreadyInserted)")

        let setResult = AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, mutable)
        guard setResult == .success else {
            RSWDiagnosticLogger.shared.log("ax_set_failed", [
                "path": "value",
                "code": setResult.rawValue,
                "valueLength": valueLength,
                "rangeLocation": replaceRange.location,
                "rangeLength": replaceRange.length
            ])
            rswDebugLog("[RSW] AX: kAXValueAttribute запись не удалась, код=\(setResult.rawValue)")
            return false
        }

        let caretRange = NSRange(
            location: replaceRange.location + (actualReplacement as NSString).length + (delimiterAlreadyInserted ? delimiterLength : 0),
            length: 0
        )
        setSelectedTextRange(caretRange, in: focused)
        return true
    }

    // MARK: - Путь 2: замена через kAXSelectedText (Excel, веб-формы)

    private func replaceViaSelectedText(
        focused: AXUIElement,
        word: String,
        replacement: String,
        delimiter: String,
        insertDelimiterIfMissing: Bool
    ) -> Bool {
        // В Excel и подобных приложениях курсор обычно стоит после введённого
        // слова. Мы не можем прочитать весь текст (нет kAXValueAttribute), но
        // можем:
        //   1. Выделить N символов перед курсором (setSelectedTextRange)
        //   2. Прочитать выделение (kAXSelectedTextAttribute) для подтверждения
        //   3. Если совпало — записать замену через AXUIElementSetAttributeValue
        //      для kAXSelectedTextAttribute (если поддерживается) или через
        //      эмуляцию ввода (CGEvent).

        let wordLength = (word as NSString).length
        let delimiterLength = (delimiter as NSString).length

        guard let originalRange = selectedTextRange(in: focused) else {
            rswDebugLog("[RSW] AX (selectedText): не удалось прочитать диапазон выделения")
            RSWDiagnosticLogger.shared.log("ax_selected_text_failed", [
                "reason": "no_selected_range",
                "wordLength": wordLength
            ])
            return false
        }

        guard originalRange.location != NSNotFound && originalRange.length == 0 else {
            rswDebugLog("[RSW] AX (selectedText): курсор не в позиции (location=\(originalRange.location), length=\(originalRange.length))")
            return false
        }

        // Если разделитель уже введён — сдвигаемся на его длину назад
        let selectionStart = Int(originalRange.location) - wordLength
        if delimiterLength > 0 && Int(originalRange.location) >= delimiterLength {
            // Проверяем, есть ли разделитель между словом и курсором
            // (в этом пути у нас нет полного текста, поэтому предполагаем,
            // что разделитель уже введён — это корректировка после пробела)
            // Ничего не делаем, выбираем только само слово
        }
        guard selectionStart >= 0 else {
            rswDebugLog("[RSW] AX (selectedText): selectionStart < 0, начало=\(selectionStart)")
            return false
        }

        let selectionRange = NSRange(location: selectionStart, length: wordLength)

        // Шаг 1: Выделить слово перед курсором
        guard setSelectedTextRange(selectionRange, in: focused) else {
            rswDebugLog("[RSW] AX (selectedText): не удалось выделить диапазон {\(selectionRange.location), \(selectionRange.length)}")
            return false
        }

        // Шаг 2: Прочитать выделенный текст для подтверждения
        var selectedTextValue: AnyObject?
        let selectedTextResult = AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        guard selectedTextResult == .success,
              let selectedText = selectedTextValue as? String else {
            rswDebugLog("[RSW] AX (selectedText): не удалось прочитать kAXSelectedTextAttribute, код=\(selectedTextResult.rawValue)")
            // Если не можем прочитать выделение — пробуем всё равно заменить,
            // т.к. в Excel kAXSelectedTextAttribute может не поддерживаться,
            // но setSelectedTextRange + set value может работать.
            // Но без подтверждения — слишком опасно. Откатываем выделение.
            setSelectedTextRange(originalRange, in: focused)
            RSWDiagnosticLogger.shared.log("ax_selected_text_failed", [
                "reason": "no_selected_text",
                "code": selectedTextResult.rawValue,
                "wordLength": wordLength
            ])
            return false
        }

        guard selectedText.caseInsensitiveCompare(word) == .orderedSame else {
            rswDebugLog("[RSW] AX (selectedText): выделенный текст '\(selectedText)' не совпадает с ожидаемым '\(word)'")
            setSelectedTextRange(originalRange, in: focused)
            return false
        }

        rswDebugLog("[RSW] AX (selectedText): выделение подтверждено, '\(selectedText)' == '\(word)'")

        // Шаг 3: Заменить выделенный текст
        // Пробуем kAXSelectedTextAttribute — в некоторых приложениях работает
        // запись через AXUIElementSetAttributeValue(kAXSelectedTextAttribute).
        // В Excel это может не сработать, поэтому фолбэкаем на CGEvent.
        let fullReplacement = replacement + (insertDelimiterIfMissing ? delimiter : "")

        let setSelectedResult = AXUIElementSetAttributeValue(
            focused, kAXSelectedTextAttribute as CFString, fullReplacement as CFTypeRef
        )
        if setSelectedResult == .success {
            rswDebugLog("[RSW] AX (selectedText): замена через kAXSelectedTextAttribute успешна")
            // Восстановим курсор после замены
            let newCaretLocation = selectionStart + (fullReplacement as NSString).length
            setSelectedTextRange(NSRange(location: newCaretLocation, length: 0), in: focused)
            return true
        }

        rswDebugLog("[RSW] AX (selectedText): kAXSelectedTextAttribute не поддерживается (код=\(setSelectedResult.rawValue)), пробуем CGEvent")

        // Шаг 4: Фолбэк — эмуляция ввода через CGEvent (удаляем выделение и
        // вводим замену). Это работает в Excel и большинстве нестандартных полей.
        // Удаляем выделенное слово (один Backspace для выделенного текста)
        guard let deleteDown = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true),
              let deleteUp = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) else {
            rswDebugLog("[RSW] AX (selectedText): не удалось создать CGEvent для Delete")
            setSelectedTextRange(originalRange, in: focused)
            return false
        }
        deleteDown.post(tap: CGEventTapLocation.cghidEventTap)
        deleteUp.post(tap: CGEventTapLocation.cghidEventTap)

        // Вводим замену посимвольно через CGEvent
        for ch in fullReplacement {
            typeCharacterViaCGEvent(ch)
        }

        rswDebugLog("[RSW] AX (selectedText): замена через CGEvent выполнена, длина=\(fullReplacement.count)")
        RSWDiagnosticLogger.shared.log("correction_applied", [
            "path": "selected_text_cg_event",
            "wordLength": wordLength,
            "replacementLength": fullReplacement.count
        ])
        return true
    }

    /// Ввод одного символа через CGEvent (фолбэк для приложений без AX-записи)
    private func typeCharacterViaCGEvent(_ char: Character) {
        let utf16 = Array(String(char).utf16)
        guard let eventDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let eventUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
        eventDown.flags = []
        eventDown.setIntegerValueField(CGEventField.keyboardEventKeycode, value: 0)
        utf16.withUnsafeBufferPointer { ptr in
            eventDown.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
        }
        eventDown.post(tap: CGEventTapLocation.cghidEventTap)

        eventUp.flags = []
        eventUp.setIntegerValueField(CGEventField.keyboardEventKeycode, value: 0)
        utf16.withUnsafeBufferPointer { ptr in
            eventUp.keyboardSetUnicodeString(stringLength: ptr.count, unicodeString: ptr.baseAddress)
        }
        eventUp.post(tap: CGEventTapLocation.cghidEventTap)
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
        wordBuffer.reset()

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

        // Если guard выше сработал на несовпадении подстроки — это другая
        // причина, не ax_unavailable. Логируем отдельно.
        RSWDiagnosticLogger.shared.log("manual_switch_failed", [
            "reason": "stale_or_mismatched_substring",
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
