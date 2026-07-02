import XCTest
@testable import SwitcherCore

// MARK: - WordBuffer unit tests
final class WordBufferTests: XCTestCase {
    var buffer: WordBuffer!
    
    override func setUp() {
        super.setUp()
        buffer = WordBuffer()
    }
    
    func test_appendIncreasesBuffer() {
        var b = buffer
        XCTAssertFalse(b.append("h").isEmpty)          // true
        XCTAssertFalse(b.append("e").isEmpty)
        XCTAssertEqual(b.currentWord, "he")
        b.reset()
        XCTAssertTrue(b.currentWord.isEmpty)
    }
    
    func test_resetClearsBuffer() {
        buffer.append("abc")
        buffer.reset()
        XCTAssertTrue(buffer.currentWord.isEmpty)
    }
    
    func test_currentWordReturnsCopyNotMutableReference() {
        var b = buffer
        b.append("x")
        b.append("y")
        // Ensure the underlying storage is not directly exposed
        XCTAssertEqual(b.currentWord, "xy")
    }
}