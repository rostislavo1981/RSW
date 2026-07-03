import Foundation

public enum KeyboardLanguage: Equatable {
    case english
    case russian
}

public enum LayoutRejectionReason: Equatable {
    case tooShort
    case mixedLayout
    case sourceIsKnownCorrect
    case targetUnknown
    case sourceNotPlausible
    case lowConfidence
    case alreadyValid
}

public struct LayoutRejection: Equatable {
    public let reason: LayoutRejectionReason
    public let sourceScore: Int
    public let targetScore: Int
    public let targetLanguage: KeyboardLanguage?
    public let mappedText: String?

    public init(
        reason: LayoutRejectionReason,
        sourceScore: Int = 0,
        targetScore: Int = 0,
        targetLanguage: KeyboardLanguage? = nil,
        mappedText: String? = nil
    ) {
        self.reason = reason
        self.sourceScore = sourceScore
        self.targetScore = targetScore
        self.targetLanguage = targetLanguage
        self.mappedText = mappedText
    }
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
    public static let englishKeys = "`qwertyuiop[]asdfghjkl;'zxcvbnm,."
    public static let russianKeys = "ёйцукенгшщзхъфывапролджэячсмитьбю"

    public static let englishCommon: Set<String> = [
        "th", "he", "in", "er", "an", "re", "on", "at", "en", "nd", "ti", "es",
        "or", "te", "of", "ed", "is", "it", "al", "ar", "st", "to", "nt", "ng",
        "se", "ha", "as", "ou", "io", "le", "ve", "co", "me", "de", "hi", "ri",
        "ro", "ic", "ne", "ea", "ra", "ce", "li", "ch", "ll", "be", "ma", "si"
    ]
    public static let russianCommon: Set<String> = [
        "ст", "но", "то", "на", "ен", "ов", "ни", "ра", "во", "ко", "ро", "по",
        "ос", "ер", "пр", "го", "ал", "ли", "от", "ре", "де", "та", "ть", "ка",
        "ет", "ло", "ор", "ан", "ва", "те", "ел", "ит", "ар", "ый", "ла", "ве",
        "ин", "ом", "ри", "не", "мо", "ся", "ми", "до", "че", "ск", "ил", "со",
        "бу", "уд", "ду", "ут", "ур", "ру", "кт", "тр", "ту", "фе", "еш", "ль"
    ]

    public static let englishRare: Set<Character> = ["й", "ц", "ш", "щ", "ы", "э", "ю", "я"]
    public static let russianImpossible: Set<String> = [
        "q", "w", "x", "j", "zh", "sh", "ch", "th", "wh", "ck", "ph"
    ]
    public static let suspiciousRussianCharacters: Set<Character> = [
        "ё", "й", "ц", "щ", "ъ", "ы", "ь", "э", "ю"
    ]
    public static let suspiciousRussianPairs: Set<String> = [
        "еу", "уы", "уе", "дд", "щщ", "ьф", "фс", "цщ", "щк", "ыц", "шс", "ср"
    ]

    public let englishToRussian: [Character: Character]
    public let russianToEnglish: [Character: Character]
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

        if dictionary.isKnown(lower, language: sourceLanguage) {
            return nil
        }

        if dictionary.isKnown(converted, language: targetLanguage) {
            return Conversion(
                text: preserveCase(from: word, in: converted),
                language: targetLanguage
            )
        }

        let sourceScore = score(lower, as: sourceLanguage)
        let targetScore = score(converted, as: targetLanguage)

        guard sourceLooksLikeWrongLayout(
            source: lower,
            converted: converted,
            sourceLanguage: sourceLanguage,
            sourceScore: sourceScore,
            targetScore: targetScore
        ) else {
            return nil
        }

        guard targetScore >= 2, targetScore - sourceScore >= 3 else { return nil }

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

    /// Расширенная версия `convert(_:)`, которая возвращает подробности
    /// отказа вместо голого `nil`.  Используется `ConversionBuilder`,
    /// чтобы избежать повторного вычисления `sourceScore`/`targetScore`
    /// и `sourceLooksLikeWrongLayout` после того, как `convert` уже всё
    /// проверил.
    ///
    /// Возвращаемые пары:
    ///   • `(.success(conversion), nil)` — автоконвертация разрешена;
    ///   • `(nil, rejection)` — отказ с указанием причины и, по возможности,
    ///     исходных метрик для диагностики.
    public func convertWithDiagnostics(_ word: String) -> (success: Conversion?, rejection: LayoutRejection?) {
        let minLength = 3
        guard word.count >= minLength else {
            return (nil, LayoutRejection(reason: .tooShort))
        }

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
            return (nil, LayoutRejection(reason: .mixedLayout))
        }

        guard converted.count == lower.count else {
            return (nil, LayoutRejection(reason: .mixedLayout, mappedText: converted))
        }

        let targetLanguage: KeyboardLanguage = sourceLanguage == .english ? .russian : .english

        if dictionary.isKnown(lower, language: sourceLanguage) {
            return (nil, LayoutRejection(
                reason: .sourceIsKnownCorrect,
                targetLanguage: targetLanguage,
                mappedText: converted
            ))
        }

        if dictionary.isKnown(converted, language: targetLanguage) {
            return (
                Conversion(text: preserveCase(from: word, in: converted), language: targetLanguage),
                nil
            )
        }

        let sourceScore = score(lower, as: sourceLanguage)
        let targetScore = score(converted, as: targetLanguage)

        guard sourceLooksLikeWrongLayout(
            source: lower,
            converted: converted,
            sourceLanguage: sourceLanguage,
            sourceScore: sourceScore,
            targetScore: targetScore
        ) else {
            return (nil, LayoutRejection(
                reason: .alreadyValid,
                sourceScore: sourceScore,
                targetScore: targetScore,
                targetLanguage: targetLanguage,
                mappedText: converted
            ))
        }

        guard targetScore >= 2, targetScore - sourceScore >= 3 else {
            return (nil, LayoutRejection(
                reason: .lowConfidence,
                sourceScore: sourceScore,
                targetScore: targetScore,
                targetLanguage: targetLanguage,
                mappedText: converted
            ))
        }

        return (
            Conversion(text: preserveCase(from: word, in: converted), language: targetLanguage),
            nil
        )
    }

    public func map(_ value: String, using table: [Character: Character]) -> String {
        String(value.compactMap { table[$0] })
    }

    public func score(_ value: String, as language: KeyboardLanguage) -> Int {
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

    private func sourceLooksLikeWrongLayout(
        source: String,
        converted: String,
        sourceLanguage: KeyboardLanguage,
        sourceScore: Int,
        targetScore: Int
    ) -> Bool {
        switch sourceLanguage {
        case .english:
            let hasLayoutPunctuation = source.contains { "`[];',.".contains($0) }
            let hasEnglishVowel = source.contains { "aeiouy".contains($0) }
            let hasAwkwardEnglishKey = source.contains { "qwxj".contains($0) }
            return hasLayoutPunctuation || !hasEnglishVowel || hasAwkwardEnglishKey || sourceScore < 0

        case .russian:
            guard !converted.contains(where: { "`[];',.".contains($0) }) else {
                return false
            }

            let pairs = zip(source, source.dropFirst()).map { String([$0, $1]) }
            let hasSuspiciousCharacter = source.contains { Self.suspiciousRussianCharacters.contains($0) }
            let hasSuspiciousPair = pairs.contains { Self.suspiciousRussianPairs.contains($0) }
            let sourceLooksPlausible = sourceScore >= 3
            let targetIsMuchBetter = targetScore - sourceScore >= 6

            return (hasSuspiciousCharacter || hasSuspiciousPair || !sourceLooksPlausible) && targetIsMuchBetter
        }
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
