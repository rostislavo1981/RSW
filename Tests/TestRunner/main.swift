import Foundation
import SwitcherCore

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String) {
    if condition {
        passed += 1
        print("  ✓ \(message)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String) {
    assert(a == b, "\(message) (got \(String(describing: a)), expected \(String(describing: b)))")
}

func assertNil(_ value: Any?, _ message: String) {
    assert(value == nil, message)
}

func XCTAssertNotNil(_ value: Any?, _ message: String) {
    assert(value != nil, message)
}

// ============================================================
print("=== LayoutConverter Tests ===\n")

let converter = LayoutConverter()

// MARK: - EN→RU
print("EN→RU conversion:")
assertEqual(converter.convert("ghbdtn"), Conversion(text: "привет", language: .russian), "ghbdtn → привет")
assertEqual(converter.convert("pfv"), nil, "pfv too short for auto-convert")
assertEqual(converter.convert("ghtl"), Conversion(text: "пред", language: .russian), "ghtl → пред")

// MARK: - RU→EN
print("\nRU→EN conversion:")
assertEqual(converter.convert("руддщ"), Conversion(text: "hello", language: .english), "руддщ → hello")

// MARK: - Preserve correct words
print("\nPreserve correct words:")
assertNil(converter.convert("hello"), "hello preserved")
assertNil(converter.convert("привет"), "привет preserved")
assertNil(converter.convert("мир"), "мир preserved")
assertNil(converter.convert("world"), "world preserved")

// MARK: - Common words preserved
print("\nCommon words preserved:")
["и", "в", "не", "на", "я", "что", "он", "с", "а", "это", "как", "все", "она", "так", "его", "но"].forEach {
    assertNil(converter.convert($0), "'\($0)' preserved")
}
["the", "is", "it", "in", "on", "at", "to", "of", "and", "an"].forEach {
    assertNil(converter.convert($0), "'\($0)' preserved")
}

// MARK: - Short words ignored
print("\nShort words ignored:")
assertNil(converter.convert("a"), "single char ignored")
assertNil(converter.convert("й"), "single RU char ignored")
assertNil(converter.convert("ab"), "2 chars ignored")
assertNil(converter.convert("йц"), "2 RU chars ignored")

// MARK: - Mixed languages
print("\nMixed languages ignored:")
assertNil(converter.convert("helloпривет"), "mixed ignored")
assertNil(converter.convert("abcйцук"), "mixed ignored")
assertNil(converter.convert("test123"), "with numbers ignored")

// MARK: - Empty
print("\nEmpty/whitespace:")
assertNil(converter.convert(""), "empty ignored")
assertNil(converter.convert(" "), "space ignored")

// MARK: - Force convert
print("\nForce conversion:")
assertEqual(converter.forceConvert("ghbdtn"), Conversion(text: "привет", language: .russian), "force ghbdtn")
assertEqual(converter.forceConvert("руддщ"), Conversion(text: "hello", language: .english), "force руддщ")
assertEqual(converter.forceConvert("Ghbdtn"), Conversion(text: "Привет", language: .russian), "force Ghbdtn")
assertEqual(converter.forceConvert("GHBDTN"), Conversion(text: "ПРИВЕТ", language: .russian), "force GHBDTN")
assert(converter.forceConvert("q") != nil, "force single char")
assert(converter.forceConvert("q")?.language == .russian, "force q → ru")

// MARK: - Capitalization
print("\nCapitalization:")
assertEqual(converter.forceConvert("Ghbdtn")?.text, "Привет", "first cap preserved")
assertEqual(converter.forceConvert("GHBDTN")?.text, "ПРИВЕТ", "all caps preserved")
assertEqual(converter.forceConvert("ghbdtn")?.text, "привет", "lowercase preserved")

// MARK: - Character mapping
print("\nCharacter mapping:")
assertEqual(converter.forceConvert("q")?.text, "й", "q → й")
assertEqual(converter.forceConvert("й")?.text, "q", "й → q")
assertEqual(converter.forceConvert("qwertyuiop")?.text.count, 10, "mapping length preserved")

// MARK: - Russian character check
print("\nRussian character check:")
assert(LayoutConverter.isRussianCharacter("а"), "а is russian")
assert(LayoutConverter.isRussianCharacter("я"), "я is russian")
assert(LayoutConverter.isRussianCharacter("ё"), "ё is russian")
assert(!LayoutConverter.isRussianCharacter("a"), "a is not russian")
assert(!LayoutConverter.isRussianCharacter("z"), "z is not russian")
assert(!LayoutConverter.isRussianCharacter("0"), "0 is not russian")

// ============================================================
print("\n=== WordDictionary Tests ===\n")

let dict = WordDictionary()
dict.add("тестовое", language: .russian)
dict.add("customword", language: .english)

assert(dict.isKnown("тестовое", language: .russian), "known RU word")
assert(dict.isKnown("customword", language: .english), "known EN word")
assert(!dict.isKnown("unknown", language: .russian), "unknown not found")
assert(!dict.isKnown("тестовое", language: .english), "RU word not in EN dict")
assert(dict.englishCount >= 1, "EN dict has words")
assert(dict.russianCount >= 1, "RU dict has words")

dict.remove("тестовое", language: .russian)
assert(!dict.isKnown("тестовое", language: .russian), "removed word not found")

// Built-in words
assert(dict.isKnown("и", language: .russian), "built-in RU 'и'")
assert(dict.isKnown("the", language: .english), "built-in EN 'the'")

// MARK: - Dictionary integration
print("\nDictionary integration:")
let dictConv = LayoutConverter(dictionary: dict)
dict.add("пред", language: .russian)
assertEqual(dictConv.convert("ghtl"), Conversion(text: "пред", language: .russian), "dict boost: ghtl → пред")

let dictConv2 = LayoutConverter(dictionary: dict)
assertNil(dictConv2.convert("hello"), "dict doesn't change correct words")

// ============================================================
print("\n=============================")
print("Results: \(passed) passed, \(failed) failed")
if failed > 0 {
    exit(1)
}
