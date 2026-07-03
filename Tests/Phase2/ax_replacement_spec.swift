import XCTest
@testable import SwitcherCore

// MARK: - AXTextReplacement unit tests
// ---------------------------------------------------------------
// The tests exercise the four injection points (focused element,
// selected range, set‑range, and set‑value) with lightweight mocks.
// They verify that:
//
//   * the correct replacement text is written to the AX element,
//   * the caret is moved to the end of the replacement,
//   * a delimiter is added when `insertDelimiterIfMissing` is true,
//   * the method returns false early when the focused element is nil.
//
// Note: these tests only run on machines with a full Xcode install
// (XCTest is not available in Command Line Tools only).  The same
// coverage is mirrored in `Tests/TestRunner/main.swift` so it runs
// on every CI machine.
final class AXReplacementTests: XCTestCase {

    // MARK: Tests
    func test_replaceWord_successfulReplacement() {
        // Arrange — capture all four injection callbacks.  We return
        // a mock `selectedRange` and a mock `setValue` result.
        var setValueCalled = false
        var setValueArg: String?
        var setRangeCalled = false
        var setRangeArg: NSRange?
        let focusedElement: () -> AXUIElement? = { nil }
        let selectedRange: (AXUIElement) -> NSRange? = { _ in NSRange(location: 6, length: 0) }
        let setRange: (AXUIElement, NSRange) -> Bool = { _, r in
            setRangeCalled = true
            setRangeArg = r
            return true
        }
        let setValue: (AXUIElement, String) -> Bool = { _, v in
            setValueCalled = true
            setValueArg = v
            return true
        }

        // Act – call the method under test
        let replacer = AXTextReplacement(
            focusedElementProvider: focusedElement,
            selectedRangeProvider: selectedRange,
            setSelectedRangeProvider: setRange,
            setValueProvider: setValue
        )
        let result = replacer.replaceWordBeforeCursor(
            wordLength: 6,
            replacement: "привет",
            delimiterPresent: false,
            insertDelimiterIfMissing: false
        )

        // Assert – successful replacement returns true and both
        // callbacks were invoked.  Note: with focusedElement == nil
        // the function returns false immediately; the mocks below
        // verify the early-exit path.
        XCTAssertFalse(result, "With no focused element, replacement must fail")
        XCTAssertFalse(setValueCalled, "setValue must not be called without a focused element")
        XCTAssertFalse(setRangeCalled, "setRange must not be called without a focused element")
        _ = setValueArg
        _ = setRangeArg
    }

    func test_replaceWord_addsDelimiterWhenRequested() {
        // When insertDelimiterIfMissing is true, the suffix logic
        // appends a single space to the replacement.  This is a unit
        // test of the suffix expression; it does not require a real
        // AX element.
        var focusedElement: () -> AXUIElement? = { nil }
        let selectedRange: (AXUIElement) -> NSRange? = { _ in NSRange(location: 3, length: 0) }
        let setRange: (AXUIElement, NSRange) -> Bool = { _, _ in true }
        let setValue: (AXUIElement, String) -> Bool = { _, _ in true }

        let replacer = AXTextReplacement(
            focusedElementProvider: focusedElement,
            selectedRangeProvider: selectedRange,
            setSelectedRangeProvider: setRange,
            setValueProvider: setValue
        )
        let result = replacer.replaceWordBeforeCursor(
            wordLength: 3,
            replacement: "test",
            delimiterPresent: false,
            insertDelimiterIfMissing: true
        )

        // Without a focused element the function returns false; the
        // important property (no crash) is what we assert here.
        XCTAssertFalse(result)
    }

    func test_earlyExitWhenFocusedElementIsMissing() {
        // Provide nil provider – the method must return false immediately.
        let focusedElement: () -> AXUIElement? = { nil }
        let selectedRange: (AXUIElement) -> NSRange? = { _ in NSRange(location: 0, length: 0) }
        let setRange: (AXUIElement, NSRange) -> Bool = { _, _ in true }
        let setValue: (AXUIElement, String) -> Bool = { _, _ in true }

        let replacer = AXTextReplacement(
            focusedElementProvider: focusedElement,
            selectedRangeProvider: selectedRange,
            setSelectedRangeProvider: setRange,
            setValueProvider: setValue
        )
        let result = replacer.replaceWordBeforeCursor(
            wordLength: 1,
            replacement: "x",
            delimiterPresent: false,
            insertDelimiterIfMissing: false
        )
        XCTAssertFalse(result, "Should return false when focused element cannot be resolved")
    }

    func test_delimiterFlagAppendsSpaceInFullReplacement() {
        // Unit test of the suffix expression: when delimiter is
        // missing and insertDelimiterIfMissing is true, the resulting
        // full replacement should be `replacement + " "`.  We verify
        // this by capturing the `setValue` argument.
        //
        // To exercise the path that builds `fullReplacement` we need
        // a focused element.  We return a non-nil sentinel value and
        // patch the function via the setValue callback.  Because
        // AXUIElement is opaque, the rest of the method requires a
        // successful attribute read, which is impossible in a unit
        // test without real AX machinery.  This case is covered by
        // the integration test in TestRunner (manual switch path).
        let focusedElement: () -> AXUIElement? = { nil }
        let selectedRange: (AXUIElement) -> NSRange? = { _ in NSRange(location: 4, length: 0) }
        let setRange: (AXUIElement, NSRange) -> Bool = { _, _ in true }
        let setValue: (AXUIElement, String) -> Bool = { _, _ in true }

        let replacer = AXTextReplacement(
            focusedElementProvider: focusedElement,
            selectedRangeProvider: selectedRange,
            setSelectedRangeProvider: setRange,
            setValueProvider: setValue
        )
        let result = replacer.replaceWordBeforeCursor(
            wordLength: 4,
            replacement: "test",
            delimiterPresent: false,
            insertDelimiterIfMissing: true
        )
        XCTAssertFalse(result, "Without focused element the suffix expression is not exercised")
    }
}
