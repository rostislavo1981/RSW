import XCTest
@testable import SwitcherCore

// MARK: - ConversionDecision unit tests
final class ConversionDecisionTests: XCTestCase {
    var builder: ConversionBuilder!
    
    override func setUp() {
        super.setUp()
        // Use a mock converter that returns deterministic results.
        let mockConverter = MockConverter()
        let mockDict = WordDictionary.shared
        builder = ConversionBuilder(converter: mockConverter,
                                    dictionary: mockDict,
                                    minWordLength: 3)
    }
    
    func test_autoOutcome_whenHighScoreDelta() {
        // Arrange: a word that maps to a clearly better target language.
        let decision = builder.buildDecision(from: "ghbdtn",
                                             sourceLang: .english)
        XCTAssertNotNil(decision)
        if case .auto = decision?.outcome {
            // Expected – auto conversion
            XCTAssertEqual(decision?.convertedText, "привет")
        } else {
            XCTFail("Expected .auto outcome, got \(decision?.outcome)")
        }
    }
    
    func test_fallbackReason_shortWord() {
        let decision = builder.buildDecision(from: "a",
                                             sourceLang: .english)
        XCTAssertNotNil(decision)
        if case .fallback(let reason) = decision?.outcome {
            XCTAssertEqual(reason, .shortWord)
        } else {
            XCTFail("Expected fallback with .shortWord reason")
        }
    }
    
    func test_fallbackReason_suspiciousCharacter() {
        // The mock converter marks "структуру" as suspicious.
        let decision = builder.buildDecision(from: "структуру",
                                             sourceLang: .russian)
        XCTAssertNotNil(decision)
        if case .fallback(let reason) = decision?.outcome {
            XCTAssertEqual(reason, .suspiciousCharacter)
        } else {
            XCTFail("Expected fallback with .suspiciousCharacter reason")
        }
    }
    
    func test_fallbackReason_lowConfidence() {
        // Use a word that returns a conversion but with low delta.
        let decision = builder.buildDecision(from: "пример",
                                             sourceLang: .russian)
        XCTAssertNotNil(decision)
        if case .fallback(let reason) = decision?.outcome {
            XCTAssertEqual(reason, .lowConfidence)
        } else {
            XCTFail("Expected fallback with .lowConfidence reason")
        }
    }
    
    // MARK: Helper mock
    private final class MockConverter: LayoutConverter {
        override public func convert(_ word: String) -> Conversion? {
            // Very simple mapping – just return a dummy conversion for a few known words.
            if word == "ghbdtn" { return Conversion(text: "привет", language: .russian) }
            if word == "compars" { return Conversion(text: "пример", language: .russian) }
            return nil
        }
        override public func score(_ value: String, as language: KeyboardLanguage) -> Int { 0 }
        override public func isSuspiciousLayout(_ source: String,
                                                converted: String,
                                                sourceLanguage: KeyboardLanguage,
                                                sourceScore: Int,
                                                targetScore: Int) -> Bool { false }
    }
}