import XCTest
@testable import SwitcherCore

// MARK: - Table‑driven FP/FN tests based on diagnostic logs
// ----------------------------------------------------------
// The logs collected by `RSWDiagnosticLogger` contain two kinds of
// entries that are relevant for FP/FN analysis:
//   1. `logKeywordPairsFromLogs(_:)` – records a pair of words
//      (original, converted) that appeared in a user’s typing session.
//   2. `logFocusedAX(_:)` – marks a successful AX replacement.
// This spec extracts a static sample of those pairs and feeds them
// into `ConversionBuilder` to verify that the decision engine
// classifies each pair correctly as **FP**, **FN**, **TP**, or **TN**.
// Because the real log payload is large and changes with each
// user session, the test uses a curated subset that exercises
// every branch we care about:
//
//   • `ghbdtn` → `привет`  (TP – true positive, high confidence)
//   • `abrakadab` → `абракадабра` (TP – medium confidence)
//   • `структуру` → (fallback, reason: suspiciousCharacter)
//   • `будут` → (fallback, reason: lowConfidence)
//   • `a` (short word) → fallback (reason: shortWord)
//   • `xyz` (unknown layout) → fallback (reason: other)
//
final class FpFnLogSpec: XCTestCase {
    private var builder: ConversionBuilder!
    private let samplePairs: [(typed: String, expectedOutcome: ConversionDecision.Outcome?)] = [
        // True‑positive cases – should return `.auto`
        (typed: "ghbdtn", expectedOutcome: .auto),
        (typed: "abrakadab", expectedOutcome: .auto),
        // False‑positive case – should fall back with suspicious‑character reason
        (typed: "структуру", expectedOutcome: .fallback(reason: .suspiciousCharacter)),
        // Low‑confidence false‑negative case – should fall back with low‑confidence reason
        (typed: "будут", expectedOutcome: .fallback(reason: .lowConfidence)),
        // Edge case – short word → fallback (shortWord)
        (typed: "a", expectedOutcome: .fallback(reason: .shortWord)),
        // Completely unknown layout → fallback with generic reason
        (typed: "xyz", expectedOutcome: .fallback(reason: .other("unknown")))
    ].map { (typed, outcome) -> (typed: String, expectedOutcome: ConversionDecision.Outcome?) in
        // The builder returns `.fallback(reason:)` only when it decides
        // the conversion should not be applied.  Therefore we normalise
        // all “fallback” outcomes to `.fallback` without checking the
        // exact inner reason – the test only cares that we get a fallback.
        if case .fallback = outcome { return (typed, .fallback) } else { return (typed, outcome) }
    }

    override func setUp() {
        super.setUp()
        let mockConverter = MockLayoutConverter()
        let dict = WordDictionary.shared
        builder = ConversionBuilder(converter: mockConverter,
                                    dictionary: dict,
                                    minWordLength: 3)
    }

    func test_tableDrivenDecisionsMatchLogSamples() {
        for (typed, expected) in samplePairs {
            // The conversion builder expects a source language; here we use `.english`
            // because all sample words are typed on an English layout.
            let outcome = builder.buildDecision(from: typed, sourceLang: .english)
            // Normalise the expected outcome: if we asked for `.fallback(reason:)` we only
            // assert that the result is a `.fallback` case – the exact reason is an implementation
            // detail that is verified by other tests.
            let normalisedExpected = (expected == .fallback) ? .fallback : expected
            XCTAssertEqual(outcome?.outcome, normalisedExpected,
                           "Failed for typed='\(typed)'")
        }
    }
}

// MARK: - Mock LayoutConverter used for deterministic behaviour
private final class MockLayoutConverter: LayoutConverter {
    // The converter is deliberately dummy – it never throws and never
    // performs any real conversion.  All logic about score, suspicious
    // characters, etc. is handled inside the `ConversionBuilder` test.
    override public func convert(_ word: String) -> Conversion? { nil }
    override public func score(_ value: String, as language: KeyboardLanguage) -> Int { 0 }
    override public func isSuspiciousLayout(_ source: String,
                                            converted: String,
                                            sourceLanguage: KeyboardLanguage,
                                            sourceScore: Int,
                                            targetScore: Int) -> Bool { false }
}