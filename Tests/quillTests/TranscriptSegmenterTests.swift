import FluidAudio
import Testing
@testable import quill

@Test func dropsPunctuationOnlySegment() {
    var segmenter = IncrementalTranscriptSegmenter()

    #expect(segmenter.append([
        WordTiming(word: ".", startTime: 1, endTime: 1.1)
    ]).isEmpty)
    #expect(segmenter.finish() == nil)
}

@Test func attachesStandalonePunctuationToOpenSentence() throws {
    var segmenter = IncrementalTranscriptSegmenter()

    #expect(segmenter.append([
        WordTiming(word: "Hello", startTime: 1, endTime: 1.3)
    ]).isEmpty)
    let segments = segmenter.append([
        WordTiming(word: ".", startTime: 1.3, endTime: 1.4)
    ])

    let segment = try #require(segments.first)
    #expect(segments.count == 1)
    #expect(segment.text == "Hello.")
    #expect(segment.start == 1)
    #expect(segment.end == 1.4)
}

@Test func canonicalAndIncrementalSegmentationShareBoundaries() {
    let words = [
        WordTiming(word: "First.", startTime: 0, endTime: 0.5),
        WordTiming(word: "Second", startTime: 2, endTime: 2.4),
        WordTiming(word: "sentence!", startTime: 2.5, endTime: 3),
    ]

    let segments = TranscriptSegmenter.segments(from: words)

    #expect(segments.map(\.text) == ["First.", "Second sentence!"])
}
