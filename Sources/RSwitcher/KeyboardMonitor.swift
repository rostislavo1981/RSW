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
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            currentWord = ""
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 {
            if !currentWord.isEmpty { currentWord.removeLast() }
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
        guard isEnabled, let correction = converter.convert(word) else {
            return Unmanaged.passUnretained(event)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.replace(word: word, with: correction.text, delimiter: text)
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
        event.keyboardGetUnicodeString(
            maxStringLength: length,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        return String(utf16CodeUnits: buffer, count: length)
    }

    private func replace(word: String, with replacement: String, delimiter: String) {
        postBackspaces(word.count + delimiter.count)
        postText(replacement + delimiter)
    }

    private func postBackspaces(_ count: Int) {
        for _ in 0..<count {
            postKey(code: 51, isDown: true)
            postKey(code: 51, isDown: false)
        }
    }

    private func postKey(code: CGKeyCode, isDown: Bool) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cgSessionEventTap)
    }

    private func postText(_ text: String) {
        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        }
    }
}
