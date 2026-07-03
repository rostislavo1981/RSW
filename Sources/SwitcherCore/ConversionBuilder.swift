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

/// `ConversionBuilder` — тонкая обёртка над `LayoutConverter`,
/// которая преобразует (успех, отказ) в `ConversionDecision` с
/// человекочитаемыми причинами.  Реальный scoring и
/// `sourceLooksLikeWrongLayout` живут в `LayoutConverter` —
/// дубликат устранён (Phase 2 refactor).
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
        // 1. Локальная проверка `minWordLength` (в `convertWithDiagnostics`
        //    зашит минимум 3, но `AppSettings.minWordLength` может быть
        //    другим — поэтому проверяем здесь).
        if typed.count < minWordLength {
            return ConversionDecision(
                outcome: .fallback(reason: .shortWord),
                sourceLanguage: sourceLang,
                rejectionReason: "word length < minWordLength"
            )
        }

        // 2. Делегируем всю scoring-логику в `LayoutConverter`.  Если он
        //    говорит «auto» — сразу отдаём.  Если отказывает — берём
        //    `LayoutRejection` и транслируем в `ConversionDecision`.
        let result = converter.convertWithDiagnostics(typed)
        let dictHit: String? = dictionary.isKnown(typed.lowercased(), language: sourceLang)
            ? (sourceLang == .english ? "en" : "ru")
            : nil

        if let conversion = result.success {
            let targetLanguage: KeyboardLanguage = sourceLang == .english ? .russian : .english
            return ConversionDecision(
                outcome: .auto,
                convertedText: conversion.text,
                sourceLanguage: sourceLang,
                targetLanguage: targetLanguage,
                dictionaryHit: dictHit,
                rejectionReason: nil
            )
        }

        // 3. Транслируем причину отказа в `ConversionDecision`.  Все
        //    метрики (`sourceScore`/`targetScore`) уже посчитаны в
        //    `LayoutConverter` — повторно не вычисляем.
        guard let rejection = result.rejection else {
            return nil
        }

        let (fallbackReason, rejectionText) = mapRejection(rejection, sourceLang: sourceLang)

        return ConversionDecision(
            outcome: .fallback(reason: fallbackReason),
            sourceLanguage: sourceLang,
            targetLanguage: rejection.targetLanguage,
            sourceScore: rejection.sourceScore,
            targetScore: rejection.targetScore,
            dictionaryHit: dictHit,
            rejectionReason: rejectionText
        )
    }

    /// Транслирует низкоуровневую причину отказа `LayoutConverter` в
    /// пользовательскую причину `ConversionBuilder`.  Единственное место,
    /// где эти два набора причин сопоставляются.
    private func mapRejection(
        _ rejection: LayoutRejection,
        sourceLang: KeyboardLanguage
    ) -> (ConversionFallbackReason, String) {
        switch rejection.reason {
        case .tooShort:
            return (.other("too_short_in_converter"), "word length < 3")
        case .mixedLayout:
            return (.other("mixed_layout"), "mixed layout characters")
        case .sourceIsKnownCorrect:
            return (.other("source_known"), "typed word is already in source-language dictionary")
        case .targetUnknown:
            return (.other("target_unknown"), "mapped word not in target dictionary")
        case .sourceNotPlausible:
            return (.suspiciousCharacter, "source layout looks plausible in target language")
        case .lowConfidence:
            return (.lowConfidence, "targetScore < 2 or delta < 3")
        case .alreadyValid:
            return (.other("already_valid_in_source_layout"), "source layout already plausible")
        }
    }
}
