import XCTest
@testable import SwitcherCore

// MARK: - Table-driven FP/FN tests
//
// Проверяем `ConversionBuilder.buildDecision` на типичных словах из
// логов (FP русских слов, TP пар, EN-словарь). Без mock-объектов —
// только реальный `LayoutConverter` + in-memory `WordDictionary`.
//
final class FpFnLogSpec: XCTestCase {
    private var builder: ConversionBuilder!

    private struct Case {
        let typed: String
        let sourceLang: KeyboardLanguage
        let expectedAuto: Bool
    }

    private let cases: [Case] = [
        // True positive: явные конвертируемые пары.
        Case(typed: "ghbdtn",      sourceLang: .english, expectedAuto: true),
        Case(typed: "руддщ",       sourceLang: .russian, expectedAuto: true),
        // False positive защита: правильные русские слова не трогаем.
        Case(typed: "структуру",   sourceLang: .russian, expectedAuto: false),
        Case(typed: "будут",       sourceLang: .russian, expectedAuto: false),
        Case(typed: "машины",      sourceLang: .russian, expectedAuto: false),
        // Edge: слишком короткое.
        Case(typed: "a",           sourceLang: .english, expectedAuto: false),
        // Edge: пустое.
        // (отдельно — должно вернуть nil)
    ]

    override func setUp() {
        super.setUp()
        let dict = WordDictionary(storageURL: nil)
        let converter = LayoutConverter(dictionary: dict)
        builder = ConversionBuilder(converter: converter,
                                    dictionary: dict,
                                    minWordLength: 3)
    }

    func test_tableDriven() {
        for c in cases {
            let decision = builder.buildDecision(from: c.typed,
                                                 sourceLang: c.sourceLang)
            if c.expectedAuto {
                guard case .auto = decision?.outcome else {
                    XCTFail("'\(c.typed)' expected auto, got \(String(describing: decision?.outcome))")
                    continue
                }
            } else {
                if case .auto = decision?.outcome {
                    XCTFail("'\(c.typed)' should NOT be auto, got \(String(describing: decision?.outcome))")
                }
            }
        }
    }

    func test_emptyInputReturnsNil() {
        let decision = builder.buildDecision(from: "", sourceLang: .english)
        XCTAssertNil(decision)
    }
}
