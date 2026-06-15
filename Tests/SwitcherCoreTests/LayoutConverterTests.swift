import SwitcherCore
import XCTest

final class LayoutConverterTests: XCTestCase {
    private let converter = LayoutConverter()

    // MARK: - Basic EN→RU conversion

    func testConvertsGhbdtnToPrivet() {
        XCTAssertEqual(
            converter.convert("ghbdtn"),
            Conversion(text: "привет", language: .russian)
        )
    }

    func testConvertsRuddshToHello() {
        XCTAssertEqual(
            converter.convert("руддщ"),
            Conversion(text: "hello", language: .english)
        )
    }

    func testConvertsPfv() {
        XCTAssertEqual(
            converter.convert("pfv"),
            Conversion(text: "рор", language: .russian)
        )
    }

    func testConvertsLj() {
        let result = converter.convert("lfn")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.language, .russian)
    }

    // MARK: - Words preserved when correct

    func testPreservesEnglishHello() {
        XCTAssertNil(converter.convert("hello"))
    }

    func testPreservesRussianPrivet() {
        XCTAssertNil(converter.convert("привет"))
    }

    func testPreservesEnglishWorld() {
        XCTAssertNil(converter.convert("world"))
    }

    func testPreservesRussianMir() {
        XCTAssertNil(converter.convert("мир"))
    }

    func testPreservesCommonRussianWords() {
        let words = ["и", "в", "не", "на", "я", "что", "он", "с", "а", "это",
                     "как", "все", "она", "так", "его", "но", "да", "ты", "по"]
        for word in words {
            XCTAssertNil(converter.convert(word), "Should preserve '\(word)'")
        }
    }

    func testPreservesCommonEnglishWords() {
        let words = ["the", "is", "it", "in", "on", "at", "to", "of", "and", "an"]
        for word in words {
            XCTAssertNil(converter.convert(word), "Should preserve '\(word)'")
        }
    }

    // MARK: - Short words

    func testIgnoresSingleCharacter() {
        XCTAssertNil(converter.convert("a"))
        XCTAssertNil(converter.convert("й"))
    }

    func testIgnoresTwoCharacterWords() {
        XCTAssertNil(converter.convert("ab"))
        XCTAssertNil(converter.convert("йц"))
        XCTAssertNil(converter.convert("no"))
        XCTAssertNil(converter.convert("не"))
    }

    func testIgnoresThreeCharacterWordsThatAreCorrect() {
        XCTAssertNil(converter.convert("the"))
        XCTAssertNil(converter.convert("and"))
        XCTAssertNil(converter.convert("что"))
    }

    // MARK: - Mixed languages

    func testIgnoresMixedAlphaWords() {
        XCTAssertNil(converter.convert("helloпривет"))
        XCTAssertNil(converter.convert("abcйцук"))
        XCTAssertNil(converter.convert("testтест"))
    }

    func testIgnoresWordsWithNumbers() {
        XCTAssertNil(converter.convert("hello1"))
        XCTAssertNil(converter.convert("abc123"))
    }

    func testIgnoresWordsWithSpecialChars() {
        XCTAssertNil(converter.convert("hello!"))
        XCTAssertNil(converter.convert("test@"))
    }

    // MARK: - Empty and nil

    func testConvertsEmptyString() {
        XCTAssertNil(converter.convert(""))
    }

    func testConvertsWhitespace() {
        XCTAssertNil(converter.convert(" "))
        XCTAssertNil(converter.convert("  "))
    }

    // MARK: - Force conversion

    func testForceConvertsGhbdtn() {
        XCTAssertEqual(
            converter.forceConvert("ghbdtn"),
            Conversion(text: "привет", language: .russian)
        )
    }

    func testForceConvertsRuddshToHello() {
        XCTAssertEqual(
            converter.forceConvert("руддщ"),
            Conversion(text: "hello", language: .english)
        )
    }

    func testForceConvertsCapitalizedWord() {
        XCTAssertEqual(
            converter.forceConvert("Ghbdtn"),
            Conversion(text: "Привет", language: .russian)
        )
    }

    func testForceConvertsAllCaps() {
        XCTAssertEqual(
            converter.forceConvert("GHBDTN"),
            Conversion(text: "ПРИВЕТ", language: .russian)
        )
    }

    func testForceConvertsSingleChar() {
        XCTAssertNotNil(converter.forceConvert("q"))
        XCTAssertEqual(converter.forceConvert("q")?.language, .russian)
    }

    // MARK: - Capitalization preservation

    func testPreservesFirstLetterCapitalized() {
        let result = converter.forceConvert("Ghbdtn")
        XCTAssertEqual(result?.text, "Привет")
    }

    func testPreservesAllCaps() {
        let result = converter.forceConvert("GHBDTN")
        XCTAssertEqual(result?.text, "ПРИВЕТ")
    }

    func testPreservesLowercase() {
        let result = converter.forceConvert("ghbdtn")
        XCTAssertEqual(result?.text, "привет")
    }

    // MARK: - Dictionary integration

    func testDictionaryKnownWordConverts() {
        let dict = WordDictionary()
        dict.add("мир", language: .russian)
        let conv = LayoutConverter(dictionary: dict)
        XCTAssertEqual(
            conv.convert("ghtl"),
            Conversion(text: "мир", language: .russian)
        )
    }

    func testDictionaryKnownEnglishWordConverts() {
        let dict = WordDictionary()
        dict.add("hello", language: .english)
        let conv = LayoutConverter(dictionary: dict)
        XCTAssertEqual(
            conv.convert("руддщ"),
            Conversion(text: "hello", language: .english)
        )
    }

    func testDictionaryDoesNotAffectCorrectWords() {
        let dict = WordDictionary()
        dict.add("hello", language: .english)
        let conv = LayoutConverter(dictionary: dict)
        XCTAssertNil(conv.convert("hello"))
    }

    func testDictionaryWithEmptyDictionary() {
        let dict = WordDictionary()
        let conv = LayoutConverter(dictionary: dict)
        XCTAssertNotNil(conv.convert("ghbdtn"))
    }

    // MARK: - Russian characters

    func testIsRussianCharacter() {
        XCTAssertTrue(LayoutConverter.isRussianCharacter("а"))
        XCTAssertTrue(LayoutConverter.isRussianCharacter("я"))
        XCTAssertTrue(LayoutConverter.isRussianCharacter("ё"))
        XCTAssertFalse(LayoutConverter.isRussianCharacter("a"))
        XCTAssertFalse(LayoutConverter.isRussianCharacter("z"))
        XCTAssertFalse(LayoutConverter.isRussianCharacter("0"))
    }

    // MARK: - Mapping accuracy

    func testEnglishToRussianMapping() {
        let result = converter.forceConvert("q")
        XCTAssertEqual(result?.text, "й")
    }

    func testRussianToEnglishMapping() {
        let result = converter.forceConvert("й")
        XCTAssertEqual(result?.text, "q")
    }

    func testMappingLengthPreserved() {
        let result = converter.forceConvert("qwertyuiop")
        XCTAssertEqual(result?.text.count, 10)
    }

    func testMappingPreservesAllCharacters() {
        let result = converter.forceConvert("asdfghjkl;")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text.count, 10)
    }
}
