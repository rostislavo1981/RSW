import XCTest
@testable import SwitcherCore

// MARK: - WordBuffer unit tests
// ---------------------------------------------------------------
// These tests mirror the assertions in `Tests/TestRunner/main.swift`
// section 19 (Phase 2/4 wire-in).  The XCTest variants are kept for
// when a developer runs `RSW_ENABLE_XCTEST=1 swift test` on a
// machine with a full Xcode install.
final class WordBufferTests: XCTestCase {
    var buffer: WordBuffer!

    override func setUp() {
        super.setUp()
        buffer = WordBuffer()
    }

    func test_appendIncreasesBuffer() {
        buffer.append("h")
        buffer.append("e")
        XCTAssertEqual(buffer.currentWord, "he")
        buffer.reset()
        XCTAssertTrue(buffer.currentWord.isEmpty)
    }

    func test_resetClearsBuffer() {
        buffer.append("a")
        buffer.append("b")
        buffer.append("c")
        buffer.reset()
        XCTAssertTrue(buffer.currentWord.isEmpty)
    }

    func test_currentWordAfterMultipleAppends() {
        buffer.append("x")
        buffer.append("y")
        XCTAssertEqual(buffer.currentWord, "xy")
    }

    func test_removeLastOnEmptyIsNoop() {
        buffer.removeLast()
        XCTAssertTrue(buffer.currentWord.isEmpty)
    }

    func test_removeLastDropsLastChar() {
        buffer.append("h")
        buffer.append("e")
        buffer.append("l")
        buffer.append("l")
        buffer.append("o")
        buffer.removeLast()
        XCTAssertEqual(buffer.currentWord, "hell")
    }
}
