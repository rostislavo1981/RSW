import XCTest
@testable import SwitcherCore

// MARK: - ConversionDecision unit tests
//
// Тесты на реальный `ConversionBuilder` поверх `LayoutConverter` и
// `WordDictionary` — без mock-объектов. `LayoutConverter` это `struct`,
// поэтому subclass невозможен; вместо этого используем in-memory
// `WordDictionary(storageURL: nil)`, который не пишет на диск и не
// подмешивает built-in словарь для тестового слова.
//
final class ConversionDecisionTests: XCTestCase {
    private var builder: ConversionBuilder!
    private var dict: WordDictionary!

    override func setUp() {
        super.setUp()
        // Изолированный in-memory словарь, не трогает `~/Library/...`.
        dict = WordDictionary(storageURL: nil)
        let converter = LayoutConverter(dictionary: dict)
        builder = ConversionBuilder(converter: converter,
                                    dictionary: dict,
                                    minWordLength: 3)
    }

    func test_autoOutcome_knownPair() {
        // "ghbdtn" → "привет" — известная пара, должна пройти.
        let decision = builder.buildDecision(from: "ghbdtn", sourceLang: .english)
        XCTAssertNotNil(decision)
        guard case .auto = decision?.outcome else {
            XCTFail("Expected .auto, got \(String(describing: decision?.outcome))")
            return
        }
        XCTAssertEqual(decision?.convertedText, "привет")
    }

    func test_fallbackReason_shortWord() {
        let decision = builder.buildDecision(from: "a", sourceLang: .english)
        XCTAssertNotNil(decision)
        guard case .fallback(let reason) = decision?.outcome else {
            XCTFail("Expected fallback")
            return
        }
        XCTAssertEqual(reason, .shortWord)
    }

    func test_fallbackReason_knownInSourceDict() {
        // "hello" в английском словаре → suspiciousCharacter.
        let decision = builder.buildDecision(from: "hello", sourceLang: .english)
        XCTAssertNotNil(decision)
        guard case .fallback(let reason) = decision?.outcome else {
            XCTFail("Expected fallback")
            return
        }
        XCTAssertEqual(reason, .suspiciousCharacter)
    }

    func test_fallbackReason_noConversion() {
        // "qqq" — три неалфавитных ASCII, не конвертируется.
        let decision = builder.buildDecision(from: "qqq", sourceLang: .english)
        XCTAssertNotNil(decision)
        guard case .fallback(let reason) = decision?.outcome else {
            XCTFail("Expected fallback")
            return
        }
        // Либо lowConfidence (скор не сошёлся), либо other("no_conversion").
        // Главное что не auto.
        if case .lowConfidence = reason { return }
        if case .other(let s) = reason {
            XCTAssertFalse(s.isEmpty, "other reason should carry payload")
            return
        }
        XCTFail("Unexpected fallback reason: \(reason)")
    }

    func test_fallback_emptyInput() {
        let decision = builder.buildDecision(from: "", sourceLang: .english)
        XCTAssertNil(decision)
    }
}
