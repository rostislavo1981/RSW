import AppKit
import Foundation
import SwitcherCore

func rswDebugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["RSW_DEBUG"] == "1" else { return }
    fputs(message() + "\n", stderr)
}

final class RSWDiagnosticLogger {
    static let shared = RSWDiagnosticLogger()

    let isEnabled: Bool
    let capturesText: Bool

    private let queue = DispatchQueue(label: "rsw.diagnostics")
    private let encoder = JSONEncoder()
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let maxFileBytes: UInt64
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var currentFileBytes: UInt64 = 0
    private var lastMemoryLogAt: Date = .distantPast

    private init() {
        let env = ProcessInfo.processInfo.environment
        isEnabled = env["RSW_DIAG"] == "1"
        capturesText = env["RSW_DIAG_CAPTURE_TEXT"] == "1"
        maxFileBytes = UInt64(env["RSW_DIAG_MAX_MB"] ?? "")
            .flatMap { $0 > 0 ? $0 * 1024 * 1024 : nil } ?? 25 * 1024 * 1024

        if let customPath = env["RSW_DIAG_DIR"], !customPath.isEmpty {
            directoryURL = URL(fileURLWithPath: NSString(string: customPath).expandingTildeInPath)
        } else {
            let logs = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs")
                .appendingPathComponent("RSW")
            directoryURL = logs
        }

        guard isEnabled else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        openNewFile()
        log("diagnostics_started", [
            "captureText": capturesText,
            "directory": directoryURL.path,
            "maxFileBytes": maxFileBytes,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "version": "0.2.20"
        ])
    }

    deinit {
        fileHandle?.closeFile()
    }

    func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }

        var payload = fields
        payload["event"] = event
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        payload["processUptime"] = ProcessInfo.processInfo.systemUptime
        payload["frontmostApp"] = frontmostAppInfo()

        queue.async { [weak self] in
            self?.write(payload)
        }
    }

    func logKeyboardEvent(
        type: CGEventType,
        event: CGEvent,
        text: String?,
        currentWord: String,
        isTerminal: Bool,
        decision: String
    ) {
        guard isEnabled else { return }

        var fields: [String: Any] = [
            "cgEventType": type.rawValue,
            "keyCode": event.getIntegerValueField(.keyboardEventKeycode),
            "flags": event.flags.rawValue,
            "isTerminal": isTerminal,
            "decision": decision,
            "currentWordLength": currentWord.count,
            "eventSourceUserData": event.getIntegerValueField(.eventSourceUserData)
        ]

        if capturesText {
            fields["text"] = text ?? ""
            fields["currentWord"] = currentWord
        } else {
            fields["textLength"] = text?.count ?? 0
        }

        log("keyboard_event", fields)
    }

    func logFocusedAX(_ reason: String) {
        guard isEnabled else { return }
        log("focused_ax", focusedAXInfo(reason: reason))
    }

    /// Логирует решение `ConversionBuilder` о замене.
    /// `event`: `correction_accepted` (auto), `correction_failed` (fallback).
    /// `sourceText` — что именно пользователь набирал (для диагностики).
    func logDecision(_ decision: ConversionDecision, sourceLength: Int, sourceText: String? = nil) {
        guard isEnabled else { return }
        var fields: [String: Any] = [
            "sourceLength": sourceLength,
            "outcome": describe(decision.outcome)
        ]
        if let lang = decision.sourceLanguage {
            fields["sourceLanguage"] = lang == .russian ? "ru" : "en"
        }
        if capturesText, let text = decision.convertedText {
            fields["convertedText"] = text
        }
        // Исходное слово (что набирал пользователь) — для диагностики no_conversion.
        if capturesText, let text = sourceText {
            fields["sourceText"] = text
        }
        // Детальная диагностика: что builder решал и почему отказал.
        if capturesText {
            switch decision.outcome {
            case .auto:
                if let text = decision.convertedText {
                    fields["decision"] = "auto:'\(text)'"
                }
            case .fallback(let reason):
                switch reason {
                case .other(let msg):
                    fields["decision"] = "fail:'\(msg)'"
                case .shortWord:
                    fields["decision"] = "fail:shortWord"
                case .suspiciousCharacter:
                    fields["decision"] = "fail:knownInSourceDict"
                case .lowConfidence:
                    fields["decision"] = "fail:lowConfidence"
                }
            }
        }
        let event: String
        if case .auto = decision.outcome {
            event = "correction_accepted"
        } else {
            event = "correction_failed"
        }
        log(event, fields)
    }

    private func describe(_ outcome: ConversionOutcome) -> String {
        switch outcome {
        case .auto: return "auto"
        case .fallback(let reason):
            switch reason {
            case .shortWord: return "fallback:shortWord"
            case .suspiciousCharacter: return "fallback:suspiciousCharacter"
            case .lowConfidence: return "fallback:lowConfidence"
            case .other(let s): return "fallback:other:\(s)"
            }
        }
    }

    func logMemoryIfNeeded(interval: TimeInterval = 30) {
        guard isEnabled else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMemoryLogAt) >= interval else { return }
        lastMemoryLogAt = now

        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        log("memory", [
            "maxResidentSize": usage.ru_maxrss,
            "userTime": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
            "systemTime": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        ])
    }

    private func write(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }

        rotateIfNeeded(additionalBytes: UInt64(data.count + 1))
        fileHandle?.write(data)
        fileHandle?.write(Data([0x0A]))
        currentFileBytes += UInt64(data.count + 1)
    }

    private func rotateIfNeeded(additionalBytes: UInt64) {
        if fileHandle == nil || currentFileBytes + additionalBytes > maxFileBytes {
            fileHandle?.closeFile()
            openNewFile()
        }
    }

    private func openNewFile() {
        let stamp = Self.fileDateFormatter.string(from: Date())
        let url = directoryURL.appendingPathComponent("rsw-diagnostics-\(stamp).jsonl")
        fileManager.createFile(atPath: url.path, contents: nil)
        fileURL = url
        fileHandle = try? FileHandle(forWritingTo: url)
        currentFileBytes = 0
    }

    private func frontmostAppInfo() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return [:]
        }
        return [
            "bundleIdentifier": app.bundleIdentifier ?? "",
            "localizedName": app.localizedName ?? "",
            "processIdentifier": app.processIdentifier
        ]
    }

    private func focusedAXInfo(reason: String) -> [String: Any] {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return ["reason": reason, "available": false]
        }

        let element = focused as! AXUIElement
        var result: [String: Any] = ["reason": reason, "available": true]
        for (attribute, key) in [
            (kAXRoleAttribute, "role"),
            (kAXSubroleAttribute, "subrole"),
            (kAXTitleAttribute, "title"),
            (kAXIdentifierAttribute, "identifier")
        ] {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let string = value as? String {
                result[key] = capturesText ? string : "[redacted:\(string.count)]"
            }
        }

        if let range = selectedTextRange(in: element) {
            result["selectedRangeLocation"] = range.location
            result["selectedRangeLength"] = range.length
        }

        if capturesText, let selected = selectedText(in: element) {
            result["selectedText"] = selected
        }

        return result
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
        guard AXValueGetValue(axRange, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func selectedText(in element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String else {
            return nil
        }
        return text
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
