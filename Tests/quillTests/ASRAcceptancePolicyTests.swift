import FluidAudio
import Testing
@testable import quill

@Test func aggregatesTokenConfidenceAtWordLevel() {
    let words = buildConfidentWordTimings(from: [
        token("▁hel", start: 0, end: 0.1, confidence: 0.8),
        token("lo", start: 0.1, end: 0.2, confidence: 0.6),
        token("▁world", start: 0.3, end: 0.5, confidence: 0.9),
    ])

    #expect(words.map(\.text) == ["hello", "world"])
    #expect(abs(words[0].confidence - 0.7) < 0.0001)
    #expect(words[0].start == 0)
    #expect(words[0].end == 0.2)
}

@Test func quarantinesLowConfidenceWithoutPoisoningDuplicateHistory() {
    var reconciler = LiveWordReconciler()
    let low = ASRAcceptancePolicy.evaluate(
        result("Hello", confidence: 0.64),
        startingAt: 10,
        reconciler: &reconciler
    )
    let accepted = ASRAcceptancePolicy.evaluate(
        result("Hello", confidence: 0.65),
        startingAt: 10,
        reconciler: &reconciler
    )

    #expect(low.status == .lowConfidence)
    #expect(low.hypothesis == "Hello")
    #expect(low.words.isEmpty)
    #expect(accepted.status == .accepted)
    #expect(accepted.words.map(\.text) == ["Hello"])
}

@Test func neverFallsBackToUntimedOrDuplicateFullText() {
    var reconciler = LiveWordReconciler()
    let missing = ASRAcceptancePolicy.evaluate(
        ASRResult(
            text: "A whole phrase",
            confidence: 0.9,
            duration: 1,
            processingTime: 0.1,
            tokenTimings: nil
        ),
        startingAt: 0,
        reconciler: &reconciler
    )
    _ = ASRAcceptancePolicy.evaluate(
        result("Hello", confidence: 0.9),
        startingAt: 10,
        reconciler: &reconciler
    )
    let duplicate = ASRAcceptancePolicy.evaluate(
        result("Hello", confidence: 0.9),
        startingAt: 10,
        reconciler: &reconciler
    )

    #expect(missing.status == .missingTimings)
    #expect(missing.words.isEmpty)
    #expect(duplicate.status == .duplicatesOnly)
    #expect(duplicate.words.isEmpty)
}

@Test func marksEmptyRecognitionWithoutPromotingWords() {
    var reconciler = LiveWordReconciler()
    let evaluation = ASRAcceptancePolicy.evaluate(
        ASRResult(
            text: "",
            confidence: 0.1,
            duration: 1,
            processingTime: 0.1,
            tokenTimings: []
        ),
        startingAt: 0,
        reconciler: &reconciler
    )

    #expect(evaluation.status == .empty)
    #expect(evaluation.words.isEmpty)
}

private func result(_ text: String, confidence: Float) -> ASRResult {
    ASRResult(
        text: text,
        confidence: confidence,
        duration: 1,
        processingTime: 0.1,
        tokenTimings: [token("▁\(text)", start: 0, end: 0.4, confidence: confidence)]
    )
}

private func token(
    _ text: String,
    start: Double,
    end: Double,
    confidence: Float
) -> TokenTiming {
    TokenTiming(
        token: text,
        tokenId: 1,
        startTime: start,
        endTime: end,
        confidence: confidence
    )
}
