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

    // MARK: - Публичный API

    /// Колбэк об успешной замене (исходное слово, новое слово, целевой язык).
    var onCorrection: ((String, String, KeyboardLanguage) -> Void)?

    /// Флаг активного автопереключения (привязан к настройке).
    var isEnabled: Bool = true

    /// Минимальная длина слова для конвертации.
    private let minWordLength: Int

    // MARK: - Зависимости

    private let bufferBox = BufferBox()
    private let converter = LayoutConverter()
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

        // Модификаторы (Shift/Option/Ctrl/Cmd) не должны попадать в буфер,
        // но и не должны его сбрасывать.
        if eventType == .flagsChanged { return event }

        guard eventType == .keyDown else { return event }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let chars = typedCharacters(from: event)
        let hasCmd = event.flags.contains(.maskCommand)
        let hasCtrl = event.flags.contains(.maskControl)

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

    private func isDelimiter(_ s: String) -> Bool {
        guard let ch = s.first else { return false }
        return ch.isWhitespace || ".,;:!?\n\t".contains(ch)
    }

    private func attemptConversionOnDelimiter(typed: String) {
        let word = bufferBox.buffer.currentWord
        bufferBox.buffer.reset()
        guard word.count >= minWordLength else {
            return
        }
        guard let conversion = converter.convert(word) else {
            return
        }
        applyConversion(original: word, conversion: conversion, delimiter: typed)
    }

    private func applyConversion(original: String,
                                 conversion: Conversion,
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
            replacement: conversion.text,
            delimiterPresent: !delimiter.isEmpty,
            insertDelimiterIfMissing: false
        )

        // Подтверждаем, что фокус/приложение не изменились во время замены.
        let appAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trustedAfter = AXIsProcessTrusted()
        guard ok, appBefore == appAfter, trustedBefore == trustedAfter else {
            return
        }

        inputSources.select(conversion.language)
        onCorrection?(original, conversion.text, conversion.language)
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
