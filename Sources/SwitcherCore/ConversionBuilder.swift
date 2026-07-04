// MARK: - Decision types

public enum ConversionOutcome: Equatable {
    case auto
    case fallback(reason: ConversionFallbackReason)
}

public enum ConversionFallbackReason: Equatable {
    case shortWord
    case suspiciousCharacter
    case lowConfidence
    case other(String)            // associated payload for unknown reasons
}

public struct ConversionDecision: Equatable {
    public let outcome: ConversionOutcome
    public let convertedText: String?
    public let sourceLanguage: KeyboardLanguage?

    public init(outcome: ConversionOutcome, convertedText: String?, sourceLanguage: KeyboardLanguage?) {
        self.outcome = outcome
        self.convertedText = convertedText
        self.sourceLanguage = sourceLanguage
    }
}

// MARK: - Conversion builder

/// Строит диагностическое решение о замене: на основе `LayoutConverter`
/// и `WordDictionary` решает, применять ли конвертацию, и возвращает причину,
/// если нет. Используется для отладки/логирования.
public final class ConversionBuilder {
    private let converter: LayoutConverter
    private let dictionary: WordDictionary
    private let minWordLength: Int

    public init(converter: LayoutConverter, dictionary: WordDictionary, minWordLength: Int) {
        self.converter = converter
        self.dictionary = dictionary
        self.minWordLength = minWordLength
    }

    /// Возвращает `ConversionDecision` для введённого слова или `nil`,
    /// если слово пустое. `sourceLang` — язык раскладки, на которой набирали.
    public func buildDecision(from typed: String, sourceLang: KeyboardLanguage) -> ConversionDecision? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        // 1️⃣ Слишком короткое — отказ по минимальной длине.
        if lower.count < minWordLength {
            return ConversionDecision(outcome: .fallback(reason: .shortWord),
                                      convertedText: nil,
                                      sourceLanguage: sourceLang)
        }

        // 2️⃣ Слово уже известно в словаре для текущего языка —
        // значит оно набрано в правильной раскладке, конвертировать не нужно.
        if dictionary.isKnown(lower, language: sourceLang) {
            return ConversionDecision(outcome: .fallback(reason: .suspiciousCharacter),
                                      convertedText: nil,
                                      sourceLanguage: sourceLang)
        }

        // 3️⃣ LayoutConverter решает, можно ли сконвертировать.
        if let conversion = converter.convert(trimmed) {
            // 4️⃣ Проверим, что целевой язык — противоположный источнику.
            let targetLang: KeyboardLanguage = sourceLang == .russian ? .english : .russian
            guard conversion.language == targetLang else {
                return ConversionDecision(outcome: .fallback(reason: .other("same_layout")),
                                          convertedText: nil,
                                          sourceLanguage: sourceLang)
            }
            return ConversionDecision(outcome: .auto,
                                      convertedText: conversion.text,
                                      sourceLanguage: sourceLang)
        }

        // 3.5️⃣ Fallback через forceConvert (v0.2.21): если обычный convert
        // отказал по score-gap, но forceConvert даёт валидную замену противоположной
        // раскладки И исходное слово точно не в словаре sourceLang — это
        // вероятно нужная замена. Score-gap был слишком строгим.
        // Безопасность: converted должен быть известным словом в целевом
        // словаре — это даёт высокую confidence (как в TestRunner TP-pair).
        if let forced = converter.forceConvert(trimmed) {
            let targetLang: KeyboardLanguage = sourceLang == .russian ? .english : .russian
            guard forced.language == targetLang else {
                return ConversionDecision(outcome: .fallback(reason: .other("same_layout:forced")),
                                          convertedText: nil,
                                          sourceLanguage: sourceLang)
            }
            let forcedLower = forced.text.lowercased()
            // Проверяем что converted — известное слово в целевом языке.
            if dictionary.isKnown(forcedLower, language: targetLang) {
                return ConversionDecision(outcome: .auto,
                                          convertedText: forced.text,
                                          sourceLanguage: sourceLang)
            }
            // Целевое слово не в словаре — пусть обычный fallback сработает.
            return ConversionDecision(outcome: .fallback(reason: .other("no_conversion")),
                                      convertedText: nil,
                                      sourceLanguage: sourceLang)
        }

        // Совсем ничего не получилось.
        return ConversionDecision(outcome: .fallback(reason: .other("no_conversion")),
                                  convertedText: nil,
                                  sourceLanguage: sourceLang)
    }
}
