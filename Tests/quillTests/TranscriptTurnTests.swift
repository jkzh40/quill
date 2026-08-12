import Foundation
import Testing
@testable import quill

@Test func mergesConsecutiveSegmentsIntoOneSpeakerTurn() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("me", 1, 2, "First sentence."),
        segment("me", 2.4, 4, "Second sentence."),
    ])

    #expect(turns == [
        TranscriptTurn(
            speaker: "me",
            start: 1,
            end: 4,
            text: "First sentence. Second sentence."
        )
    ])
}

@Test func speakerChangeClosesTurnEvenDuringOverlap() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("me", 1, 4, "Let me explain."),
        segment("them", 3, 3.5, "Sure."),
        segment("me", 4, 5, "Thanks."),
    ])

    #expect(turns.map(\.speaker) == ["me", "them", "me"])
    #expect(turns.map(\.text) == ["Let me explain.", "Sure.", "Thanks."])
}

@Test func silenceClosesTurnWithoutAnotherSpeaker() {
    var assembler = TranscriptTurnAssembler()

    #expect(assembler.append(segment("me", 1, 3, "A complete thought.")).isEmpty)
    #expect(assembler.advance(to: 4.9) == nil)
    #expect(assembler.advance(to: 5) == TranscriptTurn(
        speaker: "me",
        start: 1,
        end: 3,
        text: "A complete thought."
    ))
}

@Test func longPauseStartsANewTurnForSameSpeaker() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("me", 1, 2, "Before the pause."),
        segment("me", 4.1, 5, "After the pause."),
    ])

    #expect(turns.map(\.text) == ["Before the pause.", "After the pause."])
}

@Test func attachesLeadingPunctuationAtSegmentBoundary() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("me", 1, 2, "Hello"),
        segment("me", 2, 3, ", world."),
    ])

    #expect(turns.map(\.text) == ["Hello, world."])
}

@Test func dropsRedundantLeadingPunctuationAtSegmentBoundary() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("them", 1, 2, "They prioritize."),
        segment("them", 2, 3, ", they prioritize differently."),
    ])

    #expect(turns.map(\.text) == ["They prioritize. they prioritize differently."])
}

@Test func dropsPunctuationOnlyTurnInput() {
    let turns = TranscriptTurnAssembler.turns(from: [
        segment("them", 1, 2, "."),
    ])

    #expect(turns.isEmpty)
}

@Test func rendersTurnAsHeadingAndCohesiveParagraph() {
    let block = TranscriptTurnMarkdown.block(TranscriptTurn(
        speaker: "them",
        start: 62,
        end: 65.9,
        text: "First sentence. Second sentence."
    ))

    #expect(block == "### them · 1:02–1:05\n\nFirst sentence. Second sentence.")
}

private func segment(
    _ speaker: String,
    _ start: TimeInterval,
    _ end: TimeInterval,
    _ text: String
) -> SpeakerTranscriptSegment {
    SpeakerTranscriptSegment(speaker: speaker, start: start, end: end, text: text)
}
