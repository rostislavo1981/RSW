import XCTest
@testable import SwitcherCore

// MARK: - WordBuffer unit tests
//
// Тесты на актуальный публичный API `WordBuffer`:
//   - `append(_:Character)` (mutating, без возврата)
//   - `reset()`
//   - `currentWord` (computed, `String`)
//   - `init()` (public)
//
final class WordBufferTests: XCTestCase {
    func test_init_isEmpty() {
        let buffer = WordBuffer()
        XCTAssertEqual(buffer.currentWord, "")
    }

    func test_append_appendsCharacter() {
        var buffer = WordBuffer()
        buffer.append("h")
        XCTAssertEqual(buffer.currentWord, "h")
        buffer.append("e")
        XCTAssertEqual(buffer.currentWord, "he")
    }

    func test_reset_clearsBuffer() {
        var buffer = WordBuffer()
        buffer.append("abc")
        buffer.reset()
        XCTAssertEqual(buffer.currentWord, "")
    }

    func test_currentWordReturnsCopy() {
        // currentWord — computed, не даёт мутировать внутреннее хранилище.
        var buffer = WordBuffer()
        buffer.append("x")
        buffer.append("y")
        XCTAssertEqual(buffer.currentWord, "xy")
        // Повторный вызов должен вернуть то же самое.
        XCTAssertEqual(buffer.currentWord, "xy")
    }

    func test_backspaceSimulation() {
        var buffer = WordBuffer()
        for ch in "hello" { buffer.append(ch) }
        // Симулируем backspace: очищаем и заново набиваем.
        buffer.reset()
        for ch in "hell" { buffer.append(ch) }
        XCTAssertEqual(buffer.currentWord, "hell")
    }

    func test_modifierDoesNotAppend() {
        // Только `isLetter` символы кладутся в буфер в реальном KeyboardMonitor.
        // Проверяем, что WordBuffer не делает никакой фильтрации сам —
        // фильтрация снаружи (мы не передаём не-буквы в `append`).
        var buffer = WordBuffer()
        buffer.append("a")
        buffer.append("1")  // WordBuffer не фильтрует.
        XCTAssertEqual(buffer.currentWord, "a1")
    }
}
