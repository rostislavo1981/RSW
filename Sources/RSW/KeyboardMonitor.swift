import AppKit
import ApplicationServices
import SwitcherCore

/// Координатор: ловит клавиатурные события, аккумулирует текущее слово через
/// `WordBuffer`, при разделителе запрашивает конвертацию у `LayoutConverter`
/// и, если нужно, выполняет AX‑замену через `AXTextReplacement`.
/// Никаких synthetic backspace / pasteboard fallback — только подтверждённый AX.
final class KeyboardMonitor {

    // MARK: - Константы

    /// keyCode клавиш, которые не сбрасывают текущее слово (Shift, Caps Lock и т. п.).
    private static let defaultExcludedKeyCodes: Set<Int> = [56, 60, 61, 57]

    /// Терминалы, в которых RSW не работает (pass‑through).
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "org.alacritty"
    ]

    // MARK: - Состояние

    /// `WordBuffer` — `struct` с `mutating` методами, его нельзя класть в
    /// C‑callback напрямую. Оборачиваем в класс, чтобы иметь shared mutable
    /// ссылку из event tap callback.
    private final class BufferBox {
        var buffer = WordBuffer()
    }

    // MARK: - Manual switch state

    /// Время последнего нажатия модификатора (для double-press детекта).
    private var lastModifierUpAt: Date?
    /// Какой модификатор был нажат последним.
    private var lastModifierKey: Int?
    /// Текущее состояние модификатора (зажат / отпущен).
    private var modifierIsDown: Bool = false
    /// Текущий нажатый модификатор (для .doubleModifier).
    private var currentModifierKey: Int?
    /// Окно для double-press (мс).
    private static let doubleModifierWindow: TimeInterval = 0.5

    // MARK: - Публичный API

    /// Колбэк об успешной замене (исходное слово, новое слово, целевой язык).
    var onCorrection: ((String, String, KeyboardLanguage) -> Void)?

    /// Колбэк диагностического решения: что решил `ConversionBuilder` для
    /// очередного слова-кандидата на замену. Сюда же уходят отказы —
    /// `.shortWord`, `.suspiciousCharacter`, `.other("no_conversion")`,
    /// `.other("policy_denied")` и т. п.
    var onDecision: ((String, ConversionDecision) -> Void)?

    /// Флаг активного автопереключения (привязан к настройке).
    var isEnabled: Bool = true

    /// Минимальная длина слова для конвертации.
    private let minWordLength: Int

    // MARK: - Зависимости

    private let bufferBox = BufferBox()
    private let converter = LayoutConverter()
    private let decisionBuilder: ConversionBuilder
    private let inputSources = InputSourceController()
    private let settings: AppSettings
    private let policy: AppPolicy

    // MARK: - Event tap

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Init

    init(minWordLength: Int = 3,
         settings: AppSettings = .shared,
         policy: AppPolicy = DefaultAppPolicy(settings: AppSettings.shared)) {
        self.minWordLength = minWordLength
        self.settings = settings
        self.policy = policy
        self.decisionBuilder = ConversionBuilder(
            converter: LayoutConverter(dictionary: .shared),
            dictionary: .shared,
            minWordLength: minWordLength
        )
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            if let result = monitor.handle(eventType: type, event: event) {
                return Unmanaged.passRetained(result)
            }
            return nil
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }

    // MARK: - Event handling

    private func handle(eventType: CGEventType, event: CGEvent) -> CGEvent? {
        // Событие «tap отключён системой» — просим переактивировать.
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return event
        }

        // Терминалы: pass‑through без изменений.
        if isTerminalFocused() {
            bufferBox.buffer.reset()
            return event
        }

        // Включён ли автопереключатель?
        guard isEnabled else { return event }

        // Manual switch через модификаторы.
        if eventType == .flagsChanged {
            return handleModifierEvent(event)
        }

        guard eventType == .keyDown else { return event }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let chars = typedCharacters(from: event)
        let hasCmd = event.flags.contains(.maskCommand)
        let hasCtrl = event.flags.contains(.maskControl)

        // Manual switch через комбинацию клавиш.
        if settings.manualSwitchTrigger == .key,
           keyCode == settings.manualSwitchKeyCode,
           matchesManualModifiers(event.flags) {
            manualSwitchSelectedText()
            return nil  // подавляем клавишу — мы её обработали
        }

        // Backspace — удаляем последний символ.
        if keyCode == 51 {
            let current = bufferBox.buffer.currentWord
            if !current.isEmpty {
                var trimmed = current
                trimmed.removeLast()
                bufferBox.buffer = WordBuffer()
                for ch in trimmed { bufferBox.buffer.append(ch) }
            }
            return event
        }

        // С модификаторами (Cmd/Ctrl) не вмешиваемся.
        if hasCmd || hasCtrl { return event }

        // Исключённые клавиши не сбрасывают слово.
        let excluded = settings.excludedKeys
        if excluded.contains(keyCode) { return event }

        // Разделитель — пробуем конвертировать накопленное слово.
        if isDelimiter(chars) {
            attemptConversionOnDelimiter(typed: chars)
            return event
        }

        // Обычный символ — добавляем в буфер, если это буква.
        if let ch = chars.first, ch.isLetter {
            bufferBox.buffer.append(ch)
        } else if !chars.isEmpty {
            // Не‑буквенный символ (цифра, пунктуация) сбрасывает буфер.
            bufferBox.buffer.reset()
        }
        return event
    }

    /// Детект двойного нажатия модификатора.
    /// При срабатывании вызывает `manualSwitchSelectedText()`.
    private func handleModifierEvent(_ event: CGEvent) -> CGEvent? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let isDown = event.flags.contains(.maskAlternate) ||
                     event.flags.contains(.maskShift) ||
                     event.flags.contains(.maskCommand) ||
                     event.flags.contains(.maskControl)

        // Игнорируем модификаторы, не относящиеся к нашему триггеру.
        guard settings.manualSwitchTrigger == .doubleModifier else { return event }
        let targetKeyCode = settings.manualSwitchModifierKey
        guard keyCode == targetKeyCode else { return event }

        if isDown && !modifierIsDown {
            // Modifier down
            modifierIsDown = true
            currentModifierKey = keyCode
        } else if !isDown && modifierIsDown {
            // Modifier up — кандидат на double-press
            modifierIsDown = false
            let now = Date()
            if let last = lastModifierUpAt,
               let lastKey = lastModifierKey,
               lastKey == keyCode,
               now.timeIntervalSince(last) < Self.doubleModifierWindow {
                // Double press: сработало!
                lastModifierUpAt = nil
                lastModifierKey = nil
                manualSwitchSelectedText()
            } else {
                lastModifierUpAt = now
                lastModifierKey = keyCode
            }
        }
        return event
    }

    private func matchesManualModifiers(_ flags: CGEventFlags) -> Bool {
        let required = CGEventFlags(rawValue: UInt64(settings.manualSwitchModifiers))
        let active = flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        return active == required
    }

    // MARK: - Manual switch

    /// Переключить раскладку выделенного текста. Если выделения нет —
    /// переключаем последнее набранное слово перед курсором.
    func manualSwitchSelectedText() {
        guard let focused = focusedAXElement() else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:no_focused_ax")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        if let selected = selectedText(in: focused), !selected.isEmpty {
            // Выделение есть → переключаем его.
            replaceSelectedText(selected, in: focused)
        } else {
            // Нет выделения → последнее слово перед курсором.
            manualSwitchLastWord(in: focused)
        }
    }

    private func replaceSelectedText(_ text: String, in focused: AXUIElement) {
        guard let conversion = converter.forceConvert(text) else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:no_conversion")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        // Читаем текущее значение AX element, заменяем выделенный текст,
        // записываем обратно через AXUIElementSetAttributeValue.
        var attrValue: AnyObject?
        guard AXUIElementCopyAttributeValue(focused,
                                            kAXValueAttribute as CFString,
                                            &attrValue) == .success,
              let raw = attrValue as? NSString else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:ax_unavailable")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }
        let original = raw as String
        guard let selectedRange = selectedTextRange(in: focused) else { return }

        let nsOriginal = original as NSString
        let replaced = nsOriginal.replacingCharacters(in: selectedRange,
                                                      with: conversion.text)
        let writeStatus = AXUIElementSetAttributeValue(focused,
                                                       kAXValueAttribute as CFString,
                                                       replaced as CFString)
        guard writeStatus == .success else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:ax_set_failed")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        // Сдвигаем курсор за вставленный текст.
        let newLocation = selectedRange.location + (conversion.text as NSString).length
        _ = setSelectedTextRange(NSRange(location: newLocation, length: 0), on: focused)

        inputSources.select(conversion.language)
        onCorrection?(text, conversion.text, conversion.language)
    }

    private func manualSwitchLastWord(in focused: AXUIElement) {
        // Берём последние minWordLength*3 символов перед курсором, ищем
        // границу слова и пробуем forceConvert. Без synthetic backspace.
        guard let selectedRange = selectedTextRange(in: focused),
              let rawValue = readStringAttribute(focused),
              let word = lastWordBeforeCursor(in: rawValue,
                                              cursor: selectedRange.location) else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:no_selection")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        guard let conversion = converter.forceConvert(word) else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:no_conversion")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        let wordLength = (word as NSString).length
        let wordRange = NSRange(location: selectedRange.location - wordLength,
                                length: wordLength)
        let ok = AXTextReplacement(
            focusedElementProvider: { focused },
            selectedRangeProvider: { element in self.selectedTextRange(in: element) },
            setSelectedRangeProvider: { el, range in
                self.setSelectedTextRange(range, on: el)
            }
        ).replaceWordBeforeCursor(
            wordLength: wordLength,
            replacement: conversion.text,
            delimiterPresent: false,
            insertDelimiterIfMissing: false
        )
        guard ok else {
            onDecision?("", ConversionDecision(
                outcome: .fallback(reason: .other("manual:ax_set_failed")),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }
        _ = wordRange  // silence unused warning (используется косвенно через replaceWordBeforeCursor)
        inputSources.select(conversion.language)
        onCorrection?(word, conversion.text, conversion.language)
    }

    private func lastWordBeforeCursor(in value: String, cursor: Int) -> String? {
        let nsValue = value as NSString
        guard cursor > 0, cursor <= nsValue.length else { return nil }
        // Ищем последний whitespace/пунктуацию перед курсором.
        let prefix = nsValue.substring(to: cursor)
        let scalars = Array(prefix.unicodeScalars)
        var i = scalars.count
        while i > 0 {
            let prev = scalars[i - 1]
            if CharacterSet.whitespacesAndNewlines.contains(prev) ||
               ".,;:!?".unicodeScalars.contains(prev) {
                break
            }
            i -= 1
        }
        let word = String(String.UnicodeScalarView(scalars[i..<scalars.count]))
        return word.isEmpty ? nil : word
    }

    private func selectedText(in element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            &value) == .success,
              let text = value as? String else {
            return nil
        }
        return text
    }

    private func readStringAttribute(_ element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXValueAttribute as CFString,
                                            &value) == .success,
              let raw = value as? NSString else {
            return nil
        }
        return raw as String
    }

    private func isDelimiter(_ s: String) -> Bool {
        guard let ch = s.first else { return false }
        return ch.isWhitespace || ".,;:!?\n\t".contains(ch)
    }

    private func attemptConversionOnDelimiter(typed: String) {
        let word = bufferBox.buffer.currentWord
        bufferBox.buffer.reset()
        guard word.count >= minWordLength else {
            onDecision?(word, ConversionDecision(
                outcome: .fallback(reason: .shortWord),
                convertedText: nil,
                sourceLanguage: nil
            ))
            return
        }

        // Диагностическое решение от ConversionBuilder — единая точка
        // истины для всех авто-веток (Phase 3).
        //
        // ВАЖНО: sourceLang определяется по набранному СЛОВУ, не по delimiter.
        // Раньше брался `typed` (разделитель), и для русского слова с пробелом
        // в конце всегда возвращалось .english → builder не находил замену.
        // Это был корневой баг "RSW детектирует, но не конвертирует".
        let sourceLang: KeyboardLanguage = word.allSatisfy({ LayoutConverter.isRussianCharacter($0) })
            ? .russian
            : .english
        let decision = decisionBuilder.buildDecision(from: word, sourceLang: sourceLang)
        onDecision?(word, decision ?? ConversionDecision(
            outcome: .fallback(reason: .other("empty")),
            convertedText: nil,
            sourceLanguage: sourceLang
        ))
        guard let decision, case .auto = decision.outcome,
              let replacement = decision.convertedText,
              let _ = decision.sourceLanguage else {
            return
        }

        // AppPolicy: для Electron-редакторов авто-замена разрешена
        // только если bundle ID в allow-list (Phase 4.1).
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           !policy.shouldAllowAutomaticReplacement(for: bid) {
            onDecision?(word, ConversionDecision(
                outcome: .fallback(reason: .other("policy_denied:\(bid)")),
                convertedText: nil,
                sourceLanguage: sourceLang
            ))
            return
        }

        let targetLang: KeyboardLanguage = sourceLang == .russian ? .english : .russian
        applyConversion(original: word,
                        replacement: replacement,
                        targetLang: targetLang,
                        delimiter: typed)
    }

    private func applyConversion(original: String,
                                 replacement: String,
                                 targetLang: KeyboardLanguage,
                                 delimiter: String) {
        guard let focused = focusedAXElement() else { return }

        // Сохраняем фокус/приложение до замены, чтобы не действовать вслепую.
        let appBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trustedBefore = AXIsProcessTrusted()

        let wordLength = original.count
        let ok = AXTextReplacement(
            focusedElementProvider: { focused },
            selectedRangeProvider: { element in self.selectedTextRange(in: element) },
            setSelectedRangeProvider: { el, range in
                self.setSelectedTextRange(range, on: el)
            }
        ).replaceWordBeforeCursor(
            wordLength: wordLength,
            replacement: replacement,
            delimiterPresent: !delimiter.isEmpty,
            insertDelimiterIfMissing: false
        )

        // Подтверждаем, что фокус/приложение не изменились во время замены.
        let appAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trustedAfter = AXIsProcessTrusted()
        guard ok, appBefore == appAfter, trustedBefore == trustedAfter else {
            return
        }

        inputSources.select(targetLang)
        onCorrection?(original, replacement, targetLang)
    }

    // MARK: - Helpers

    private func isTerminalFocused() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIdentifiers.contains(bid)
    }

    private func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &value) == .success,
              let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else {
            return nil
        }
        // Safe: мы только что проверили CFTypeID, downcast всегда успешен.
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    private func selectedTextRange(in element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let axRange = raw as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setSelectedTextRange(_ range: NSRange, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            axValue) == .success
    }

    /// Извлекает Unicode-строку из CGEvent (работает в event-tap callback,
    /// где NSEvent напрямую недоступен). Возвращает до 4 символов.
    private func typedCharacters(from event: CGEvent) -> String {
        var length: Int = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
