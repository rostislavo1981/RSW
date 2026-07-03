// MARK: - Decision types

public enum ConversionOutcome: Equatable {
    case auto
    case fallback(reason: ConversionFallbackReason)
}

public enum ConversionFallbackReason: Equatable {
    case shortWord
    case suspiciousCharacter
    case lowConfidence
    case other(String)
}

public struct ConversionDecision: Equatable {
    public let outcome: ConversionOutcome
    public let convertedText: String?
    public let sourceLanguage: KeyboardLanguage?
    public let targetLanguage: KeyboardLanguage?
    public let sourceScore: Int
    public let targetScore: Int
    public let dictionaryHit: String?
    public let rejectionReason: String?

    public init(
        outcome: ConversionOutcome,
        convertedText: String? = nil,
        sourceLanguage: KeyboardLanguage? = nil,
        targetLanguage: KeyboardLanguage? = nil,
        sourceScore: Int = 0,
        targetScore: Int = 0,
        dictionaryHit: String? = nil,
        rejectionReason: String? = nil
    ) {
        self.outcome = outcome
        self.convertedText = convertedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.sourceScore = sourceScore
        self.targetScore = targetScore
        self.dictionaryHit = dictionaryHit
        self.rejectionReason = rejectionReason
    }
}

// MARK: - Conversion builder

public final class ConversionBuilder {
    private let converter: LayoutConverter
    private let dictionary: WordDictionary
    private let minWordLength: Int

    public init(converter: LayoutConverter, dictionary: WordDictionary, minWordLength: Int) {
        self.converter = converter
        self.dictionary = dictionary
        self.minWordLength = minWordLength
    }

    public func buildDecision(from typed: String, sourceLang: KeyboardLanguage) -> ConversionDecision? {
        let lower = typed.lowercased()

        if lower.count < minWordLength {
            return ConversionDecision(
                outcome: .fallback(reason: .shortWord),
                sourceLanguage: sourceLang,
                rejectionReason: "word length < minWordLength"
            )
        }

        let conversion = converter.convert(lower)

        if let conversion = conversion {
            let targetLanguage: KeyboardLanguage = sourceLang == .english ? .russian : .english
            return ConversionDecision(
                outcome: .auto,
                convertedText: conversion.text,
                sourceLanguage: sourceLang,
                targetLanguage: targetLanguage,
                dictionaryHit: dictionary.isKnown(lower, language: sourceLang) ? sourceLang == .english ? "en" : "ru" : nil,
                rejectionReason: nil
            )
        }

        let dictHitSource = dictionary.isKnown(lower, language: sourceLang) ? (sourceLang == .english ? "en" : "ru") : nil
        let sourceScore = converter.score(lower, as: sourceLang)
        let targetScore: Int
        let targetLang: KeyboardLanguage

        if lower.allSatisfy({ $0.isASCII && ($0.isLetter || "`[];',.".contains($0)) }) {
            targetLang = .russian
            let mapped = converter.map(lower, using: converter.englishToRussian)
            targetScore = converter.score(mapped, as: .russian)
        } else if lower.allSatisfy({ LayoutConverter.russianKeys.contains($0) }) {
            targetLang = .english
            let mapped = converter.map(lower, using: converter.russianToEnglish)
            targetScore = converter.score(mapped, as: .english)
        } else {
            return ConversionDecision(
                outcome: .fallback(reason: .other("mixed_layout")),
                sourceLanguage: sourceLang,
                sourceScore: sourceScore,
                rejectionReason: "mixed layout characters"
            )
        }

        if lower.allSatisfy({ LayoutConverter.russianKeys.contains($0) }) {
            let pairs = zip(lower, lower.dropFirst()).map { String([$0, $1]) }
            let hasSuspiciousCharacter = lower.contains { LayoutConverter.suspiciousRussianCharacters.contains($0) }
            let hasSuspiciousPair = pairs.contains { LayoutConverter.suspiciousRussianPairs.contains($0) }
            let sourceLooksPlausible = sourceScore >= 3
            let targetIsMuchBetter = targetScore - sourceScore >= 6

            if (hasSuspiciousCharacter || hasSuspiciousPair || !sourceLooksPlausible) && targetIsMuchBetter {
                return ConversionDecision(
                    outcome: .fallback(reason: .suspiciousCharacter),
                    sourceLanguage: sourceLang,
                    targetLanguage: targetLang,
                    sourceScore: sourceScore,
                    targetScore: targetScore,
                    dictionaryHit: dictHitSource,
                    rejectionReason: "suspicious russian layout"
                )
            }
        }

        if targetScore < 2 || targetScore - sourceScore < 3 {
            return ConversionDecision(
                outcome: .fallback(reason: .lowConfidence),
                sourceLanguage: sourceLang,
                targetLanguage: targetLang,
                sourceScore: sourceScore,
                targetScore: targetScore,
                dictionaryHit: dictHitSource,
                rejectionReason: "targetScore < 2 or delta < 3"
            )
        }

        return ConversionDecision(
            outcome: .fallback(reason: .other("no_conversion")),
            sourceLanguage: sourceLang,
            targetLanguage: targetLang,
            sourceScore: sourceScore,
            targetScore: targetScore,
            dictionaryHit: dictHitSource,
            rejectionReason: "layout converter returned nil"
        )
    }
}
