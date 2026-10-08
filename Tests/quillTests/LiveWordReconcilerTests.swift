import Testing
@testable import quill

@Test func removesSameWordAtOverlappingTimestamp() {
    var reconciler = LiveWordReconciler()

    #expect(reconciler.accept([word("Hello", 1, 1.5)]).map(\.text) == ["Hello"])
    #expect(reconciler.accept([word("hello,", 1.1, 1.45)]).isEmpty)
}

@Test func removesDuplicateAtExactPersistedHalfOverlap() {
    var reconciler = LiveWordReconciler()

    #expect(reconciler.accept([word("Okay", 1, 1.16)]).count == 1)
    #expect(reconciler.accept([word("Okay", 1.08, 1.32)]).isEmpty)
}

@Test func preservesIntentionalRepetitionAtDistinctTimestamps() {
    var reconciler = LiveWordReconciler()

    let accepted = reconciler.accept([
        word("very", 1, 1.2),
        word("very", 1.25, 1.45),
        word("important", 1.5, 2),
    ])

    #expect(accepted.map(\.text) == ["very", "very", "important"])
}

@Test func preservesDifferentWordsEvenWhenTheirTimingsOverlap() {
    var reconciler = LiveWordReconciler()

    #expect(reconciler.accept([word("their", 1, 1.4)]).map(\.text) == ["their"])
    #expect(reconciler.accept([word("there", 1.1, 1.35)]).map(\.text) == ["there"])
}

@Test func sortsWordsBeforeReconcilingThem() {
    var reconciler = LiveWordReconciler()

    let accepted = reconciler.accept([
        word("second", 2, 2.4),
        word("first", 1, 1.4),
    ])

    #expect(accepted.map(\.text) == ["first", "second"])
}

private func word(_ text: String, _ start: Double, _ end: Double) -> RecognizedWord {
    RecognizedWord(text: text, start: start, end: end, confidence: 0.9)
}
