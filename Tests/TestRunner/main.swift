import Foundation
import SwitcherCore

var passed = 0
var failed = 0
var results: [(String, Bool)] = []

func test(_ label: String, _ block: () -> Bool) {
    let ok = block()
    results.append((label, ok))
    if ok { passed += 1 } else { failed += 1 }
}

let c = LayoutConverter()
let dict = WordDictionary.shared
let dictConv = LayoutConverter(dictionary: dict)

print("╔══════════════════════════════════════════════════════════╗")
print("║            RSW — comprehensive test suite                ║")
print("╚══════════════════════════════════════════════════════════╝")
print("")

// ────────────────────────────────────────────────────────
// 1. Known wrong-layout words → must convert correctly
// ────────────────────────────────────────────────────────
print("━━━ 1. Known conversion pairs ━━━")

let knownPairs: [(typed: String, expected: String)] = [
    ("ghbdtn", "привет"),
    ("руддщ", "hello"),
]

for p in knownPairs {
    test("'\(p.typed)' → '\(p.expected)'") {
        c.convert(p.typed)?.text == p.expected
    }
}

// ────────────────────────────────────────────────────────
// 2. Force conversion works for any word
// ────────────────────────────────────────────────────────
print("━━━ 2. Force conversion ━━━")

let forcePairs: [(typed: String, expected: String, lang: KeyboardLanguage)] = [
    ("hello", "руддщ", .russian),
    ("привет", "ghbdtn", .english),
]

for p in forcePairs {
    test("FORCE '\(p.typed)' → '\(p.expected)' (\(p.lang))") {
        let r = c.forceConvert(p.typed)
        return r?.text == p.expected && r?.language == p.lang
    }
}

// ────────────────────────────────────────────────────────
// 3. Short words must NOT convert (auto)
// ────────────────────────────────────────────────────────
print("━━━ 3. Short words rejected ━━━")

let shortWords = [
    "ab", "no", "ok", "hi", "we", "do", "am", "is", "it", "in",
    "йц", "фв", "яч", "ые", "уе", "му", "ри", "ти", "но", "на",
    "q", "й", "a", "z", "w", "ц",
]

for w in shortWords {
    test("SHORT '\(w)' → nil") {
        c.convert(w) == nil
    }
}

// ────────────────────────────────────────────────────────
// 4. Mixed language → must NOT convert
// ────────────────────────────────────────────────────────
print("━━━ 4. Mixed language rejected ━━━")

let mixedWords = [
    "helloпривет", "abcйцук", "testтест", "мирworld",
    "abc123", "hello1", "test!", "hello?", "мир!",
]

for w in mixedWords {
    test("MIXED '\(w)' → nil") {
        c.convert(w) == nil
    }
}

// ────────────────────────────────────────────────────────
// 5. Empty / whitespace
// ────────────────────────────────────────────────────────
print("━━━ 5. Empty/whitespace rejected ━━━")

let emptyWords = ["", " ", "\n", "\t", "  "]
for w in emptyWords {
    test("EMPTY '\(w.replacingOccurrences(of: "\n", with: "\\n"))' → nil") {
        c.convert(w) == nil
    }
}

// ────────────────────────────────────────────────────────
// 6. Known correct English words → preserved
// ────────────────────────────────────────────────────────
print("━━━ 6. Correct English words preserved ━━━")

let correctEn = [
    "hello", "world", "the", "is", "it", "in", "on", "at", "to", "of",
    "and", "an", "a", "my", "we", "he", "she", "they", "do", "no",
    "so", "if", "me", "up", "us", "be", "as", "am", "or", "by",
    "go", "ok", "hi", "this", "that", "with", "from", "have", "been",
    "will", "would", "could", "should", "can", "may", "shall",
    "not", "but", "what", "when", "where", "which", "who", "how",
    "all", "each", "every", "both", "few", "more", "most", "other",
    "shall", "must", "need", "dare", "ought",
]

for w in correctEn {
    test("EN preserved '\(w)'") {
        c.convert(w) == nil
    }
}

// ────────────────────────────────────────────────────────
// 7. Known correct Russian words → preserved
// ────────────────────────────────────────────────────────
print("━━━ 7. Correct Russian words preserved ━━━")

let correctRu = [
    "привет", "мир", "и", "в", "не", "на", "я", "что", "он", "с",
    "а", "это", "как", "все", "она", "так", "его", "но", "да", "ты",
    "к", "у", "же", "вы", "за", "по", "из", "о", "от", "до",
    "ли", "нет", "вот", "ну", "уж", "бы", "ей", "их", "сам", "уже",
    "или", "ни", "если", "там", "где", "при", "над", "тоже",
    "ему", "вас", "им", "нам", "ним", "нас", "вас", "вам", "нам",
    "вдруг", "вместе", "вместо", "вниз", "вверх", "внутри",
    "вне", "под", "перед", "после", "между", "через", "около",
    "вокруг", "вдоль", "поперёк", "направо", "налево", "назад", "вперёд",
]

for w in correctRu {
    test("RU preserved '\(w)'") {
        c.convert(w) == nil
    }
}

// ────────────────────────────────────────────────────────
// 8. Capitalization preserved in forceConvert
// ────────────────────────────────────────────────────────
print("━━━ 8. Capitalization ━━━")

test("FORCE CAPS 'GHBDTN' → 'ПРИВЕТ'") {
    c.forceConvert("GHBDTN")?.text == "ПРИВЕТ"
}
test("FORCE FirstCap 'Ghbdtn' → 'Привет'") {
    c.forceConvert("Ghbdtn")?.text == "Привет"
}
test("FORCE lower 'ghbdtn' → 'привет'") {
    c.forceConvert("ghbdtn")?.text == "привет"
}

// ────────────────────────────────────────────────────────
// 9. Character mapping accuracy
// ────────────────────────────────────────────────────────
print("━━━ 9. Character mapping ━━━")

let mapPairs: [(en: String, ru: String)] = [
    ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"),
    ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"),
    ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"),
    ("h", "р"), ("j", "о"), ("k", "л"), ("l", "д"), ("z", "я"),
    ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"),
    ("m", "ь"),
]

for p in mapPairs {
    test("MAP EN→RU '\(p.en)' → '\(p.ru)'") {
        c.forceConvert(p.en)?.text == p.ru
    }
    test("MAP RU→EN '\(p.ru)' → '\(p.en)'") {
        c.forceConvert(p.ru)?.text == p.en
    }
}

// ────────────────────────────────────────────────────────
// 10. Russian character detection
// ────────────────────────────────────────────────────────
print("━━━ 10. Russian character detection ━━━")

let ruChars: [(c: Character, expect: Bool)] = [
    ("а", true), ("я", true), ("ё", true), ("й", true), ("ь", true),
    ("a", false), ("z", false), ("0", false), (" ", false), ("!", false),
]

for p in ruChars {
    test("isRussian '\(p.c)' = \(p.expect)") {
        LayoutConverter.isRussianCharacter(p.c) == p.expect
    }
}

// ────────────────────────────────────────────────────────
// 11. Dictionary integration
// ────────────────────────────────────────────────────────
print("━━━ 11. Dictionary ━━━")

dict.add("тестовое", language: .russian)
dict.add("customword", language: .english)

test("DICT known RU 'тестовое'") { dict.isKnown("тестовое", language: .russian) }
test("DICT known EN 'customword'") { dict.isKnown("customword", language: .english) }
test("DICT unknown 'xyz' not found") { !dict.isKnown("xyz", language: .russian) }

// ────────────────────────────────────────────────────────
// 12. convert() vs forceConvert() difference
// ────────────────────────────────────────────────────────
print("━━━ 12. convert vs forceConvert ━━━")

test("convert('hello') = nil (correct word)") { c.convert("hello") == nil }
test("forceConvert('hello') != nil (force)") { c.forceConvert("hello") != nil }
test("convert('привет') = nil (correct word)") { c.convert("привет") == nil }
test("forceConvert('привет') != nil (force)") { c.forceConvert("привет") != nil }

// ────────────────────────────────────────────────────────
// 13. Edge cases: numbers in words
// ────────────────────────────────────────────────────────
print("━━━ 13. Numbers in words ━━━")

test("NUMBERS 'hello1' → nil") { c.convert("hello1") == nil }
test("NUMBERS '123abc' → nil") { c.convert("123abc") == nil }
test("NUMBERS 'abc123' → nil") { c.convert("abc123") == nil }

// ────────────────────────────────────────────────────────
// 14. Punctuation in words
// ────────────────────────────────────────────────────────
print("━━━ 14. Punctuation ━━━")

test("PUNCT 'hello!' → nil") { c.convert("hello!") == nil }
test("PUNCT 'test@' → nil") { c.convert("test@") == nil }
test("PUNCT 'привет.' → nil") { c.convert("привет.") == nil }

// ────────────────────────────────────────────────────────
// REPORT
// ────────────────────────────────────────────────────────

let total = passed + failed
let rate = total > 0 ? passed * 100 / total : 0

print("")
print("╔══════════════════════════════════════════════════════════╗")
print("║                    TEST REPORT                          ║")
print("╚══════════════════════════════════════════════════════════╝")
print("")
print("  Total:     \(total)")
print("  Passed:    \(passed)")
print("  Failed:    \(failed)")
print("  Pass rate: \(rate)%")
print("")

if failed > 0 {
    print("━━━ FAILED ━━━")
    for (label, ok) in results where !ok {
        print("  ✗ \(label)")
    }
    print("")
}

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("Completed: \(ISO8601DateFormatter().string(from: Date()))")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

if failed > 0 { exit(1) }
