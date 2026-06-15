import Foundation

public enum KeyboardLanguage: Equatable {
    case english
    case russian
}

public struct Conversion: Equatable {
    public let text: String
    public let language: KeyboardLanguage

    public init(text: String, language: KeyboardLanguage) {
        self.text = text
        self.language = language
    }
}

public struct LayoutConverter {
    private static let englishKeys = "`qwertyuiop[]asdfghjkl;'zxcvbnm,."
    private static let russianKeys = "ёйцукенгшщзхъфывапролджэячсмитьбю"

    private static let englishCommon: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ti", "es",
        "or", "te", "of", "ed", "is", "it", "al", "ar", "st", "to", "nt", "ng",
        "se", "ha", "as", "ou", "io", "le", "ve", "co", "me", "de", "hi", "ri",
        "ro", "ic", "ne", "ea", "ra", "ce", "li", "ch", "ll", "be", "ma", "si"
    ]
    private static let russianCommon: Set<String> = [
        "ст", "но", "то", "на", "ен", "ов", "ни", "ра", "во", "ко", "ро", "по",
        "ос", "ер", "пр", "го", "ал", "ли", "от", "ре", "де", "та", "ть", "ка",
        "ет", "ло", "ор", "ан", "ва", "те", "ел", "ит", "ар", "ый", "ла", "ве",
        "ин", "ом", "ри", "не", "мо", "ся", "ми", "до", "че", "ск", "ил", "со"
    ]

    private static let englishRare: Set<Character> = ["й", "ц", "ш", "щ", "ы", "э", "ю", "я"]
    private static let russianImpossible: Set<String> = [
        "q", "w", "x", "j", "zh", "sh", "ch", "th", "wh", "ck", "ph"
    ]

    private let englishToRussian: [Character: Character]
    private let russianToEnglish: [Character: Character]
    private let dictionary: WordDictionary

    public static func isRussianCharacter(_ c: Character) -> Bool {
        russianKeys.contains(c)
    }

    public init(dictionary: WordDictionary = .shared) {
        self.dictionary = dictionary
        englishToRussian = Dictionary(
            uniqueKeysWithValues: zip(Self.englishKeys, Self.russianKeys)
        )
        russianToEnglish = Dictionary(
            uniqueKeysWithValues: zip(Self.russianKeys, Self.englishKeys)
        )
    }

    public func convert(_ word: String) -> Conversion? {
        guard word.count >= 3 else { return nil }

        let lower = word.lowercased()
        let sourceLanguage: KeyboardLanguage
        let converted: String

        if lower.allSatisfy({ $0.isASCII && ($0.isLetter || "`[];',.".contains($0)) }) {
            sourceLanguage = .english
            converted = map(lower, using: englishToRussian)
        } else if lower.allSatisfy({ Self.russianKeys.contains($0) }) {
            sourceLanguage = .russian
            converted = map(lower, using: russianToEnglish)
        } else {
            return nil
        }

        guard converted.count == lower.count else { return nil }

        let targetLanguage: KeyboardLanguage = sourceLanguage == .english ? .russian : .english

        if dictionary.isKnown(converted, language: targetLanguage) && !dictionary.isKnown(lower, language: sourceLanguage) {
            return Conversion(
                text: preserveCase(from: word, in: converted),
                language: targetLanguage
            )
        }

        let sourceScore = score(lower, as: sourceLanguage)
        let targetScore = score(converted, as: targetLanguage)

        guard targetScore >= 2, targetScore - sourceScore >= 4 else { return nil }

        return Conversion(
            text: preserveCase(from: word, in: converted),
            language: targetLanguage
        )
    }

    public func forceConvert(_ word: String) -> Conversion? {
        let lower = word.lowercased()
        if lower.allSatisfy({ $0.isASCII && ($0.isLetter || "`[];',.".contains($0)) }) {
            return Conversion(
                text: preserveCase(from: word, in: map(lower, using: englishToRussian)),
                language: .russian
            )
        }
        if lower.allSatisfy({ Self.russianKeys.contains($0) }) {
            return Conversion(
                text: preserveCase(from: word, in: map(lower, using: russianToEnglish)),
                language: .english
            )
        }
        return nil
    }

    private func map(_ value: String, using table: [Character: Character]) -> String {
        String(value.compactMap { table[$0] })
    }

    private func score(_ value: String, as language: KeyboardLanguage) -> Int {
        let pairs = zip(value, value.dropFirst()).map { String([$0, $1]) }
        let common = language == .english ? Self.englishCommon : Self.russianCommon
        var result = pairs.reduce(0) { $0 + (common.contains($1) ? 2 : 0) }

        if language == .english {
            result -= Self.englishRare.reduce(0) { $0 + (value.contains($1) ? 4 : 0) }
            result -= value.filter { "`[];'".contains($0) }.count * 4
            result += value.contains(where: "aeiouy".contains) ? 1 : -3
        } else {
            result -= Self.russianImpossible.reduce(0) { $0 + (value.contains($1) ? 3 : 0) }
            result += value.contains(where: "аеёиоуыэюя".contains) ? 1 : -3
        }

        return result
    }

    private func preserveCase(from source: String, in converted: String) -> String {
        if source == source.uppercased() {
            return converted.uppercased()
        }
        if source.first?.isUppercase == true {
            return converted.prefix(1).uppercased() + converted.dropFirst()
        }
        return converted
    }
}
