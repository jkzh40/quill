import Foundation
import Testing
@testable import quill

@Test func schemaOneDocumentDecodesWithAdditiveDefaults() throws {
    let data = Data(#"""
    {
      "schema_version": 1,
      "revision": 1,
      "session_id": "legacy",
      "status": "complete",
      "started_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-01T00:01:00Z",
      "completed_at": "2026-01-01T00:01:00Z",
      "models": {"asr":"a","vad":"v","diarizer":"d"},
      "tracks": [{"id":"system","file":"system.caf","start_offset_ms":0}],
      "speakers": [],
      "utterances": [{"id":"u1","track":"system","start_ms":0,"end_ms":500,"forced_split":false}],
      "words": [{
        "id":"w1","utterance_id":"u1","track":"system","start_ms":0,"end_ms":500,
        "text":"Hello.","speaker_id":"system:unknown","speaker_state":"unknown","speaker_candidates":[]
      }],
      "speaker_spans": [],
      "turns": [{
        "id":"w1","utterance_id":"u1","track":"system","speaker_id":"system:unknown",
        "speaker_state":"unknown","start_ms":0,"end_ms":500,"text":"Hello.","word_ids":["w1"]
      }],
      "errors": []
    }
    """#.utf8)

    let document = try JSONDecoder().decode(TranscriptDocument.self, from: data)

    #expect(document.schema_version == 1)
    #expect(document.episodes.isEmpty)
    #expect(document.processing_windows.isEmpty)
    #expect(document.words[0].episode_id == nil)
    #expect(document.turns[0].processing_window_ids == ["u1"])
}

@Test func diarizationCanReprojectExistingWordsWithoutChangingFacts() throws {
    let source = word("hello", id: "word-1", start: 1_000, end: 1_400)

    let pending = TranscriptProjector.projectWords(
        [source],
        spans: [],
        finalizedThroughMs: [:]
    )
    #expect(pending[0].speaker_id == "system:pending")
    #expect(pending[0].speaker_state == .pending)

    let corrected = TranscriptProjector.projectWords(
        [source],
        spans: [span("system:speaker-2", start: 900, end: 1_500, activity: 0.8)],
        finalizedThroughMs: [.system: 2_000]
    )
    #expect(corrected[0].id == source.id)
    #expect(corrected[0].text == source.text)
    #expect(corrected[0].speaker_id == "system:speaker-2")
    #expect(corrected[0].speaker_state == .final)
}

@Test func projectionUsesGreatestOverlapThenActivityAsTieBreaker() {
    let source = word("overlap", id: "word-1", start: 1_000, end: 2_000)
    let projected = TranscriptProjector.projectWords(
        [source],
        spans: [
            span("system:speaker-1", start: 900, end: 1_500, activity: 0.9),
            span("system:speaker-2", start: 1_500, end: 2_100, activity: 0.7),
        ],
        finalizedThroughMs: [.system: 2_100]
    )
    #expect(projected[0].speaker_id == "system:speaker-1")
    #expect(projected[0].speaker_candidates.map(\.speaker_id) == [
        "system:speaker-1", "system:speaker-2",
    ])
}

@Test func turnsArePureProjectionOfWordsAndSpeakerChanges() {
    let raw = [
        word("Hello", id: "w1", start: 0, end: 200),
        word("there.", id: "w2", start: 210, end: 500),
        word("Yes.", id: "w3", start: 510, end: 800),
    ]
    let spans = [
        span("system:speaker-1", start: 0, end: 500),
        span("system:speaker-2", start: 500, end: 900),
    ]
    let projected = TranscriptProjector.projectWords(
        raw,
        spans: spans,
        finalizedThroughMs: [.system: 900]
    )
    let turns = TranscriptProjector.turns(from: projected)

    #expect(turns.map(\.speaker_id) == ["system:speaker-1", "system:speaker-2"])
    #expect(turns.map(\.text) == ["Hello there.", "Yes."])
}

@Test func turnsSpanProcessingWindowsAndEpisodes() {
    let words = [
        word(
            "One", id: "w1", start: 0, end: 300,
            speaker: "system:speaker-1", episode: "episode-1", window: "window-1"
        ),
        word(
            "thought.", id: "w2", start: 1_500, end: 1_900,
            speaker: "system:speaker-1", episode: "episode-2", window: "window-2"
        ),
    ]

    let turns = TranscriptProjector.turns(from: words)

    #expect(turns.count == 1)
    #expect(turns[0].text == "One thought.")
    #expect(turns[0].episode_ids == ["episode-1", "episode-2"])
    #expect(turns[0].processing_window_ids == ["window-1", "window-2"])
    #expect(turns[0].utterance_id == "window-1")
}

@Test func longPauseOrInterveningSpeakerStartsANewTurn() {
    let longPause = [
        word("First.", id: "w1", start: 0, end: 300, speaker: "system:speaker-1"),
        word("Second.", id: "w2", start: 2_301, end: 2_700, speaker: "system:speaker-1"),
    ]
    #expect(TranscriptProjector.turns(from: longPause).count == 2)

    let interruption = [
        word("First.", id: "w1", start: 0, end: 500, speaker: "system:speaker-1"),
        word("Yes.", id: "w2", start: 700, end: 900, speaker: "mic:speaker-1", track: .mic),
        word("Second.", id: "w3", start: 1_100, end: 1_500, speaker: "system:speaker-1"),
    ]
    #expect(TranscriptProjector.turns(from: interruption).map(\.text) == [
        "First.", "Yes.", "Second.",
    ])
}

@Test func overlappingSpeakerDoesNotFragmentAnotherSpeakersTurn() {
    let words = [
        word("Keep", id: "w1", start: 0, end: 1_000, speaker: "system:speaker-1"),
        word("talking.", id: "w2", start: 1_100, end: 1_600, speaker: "system:speaker-1"),
        word("Overlap.", id: "w3", start: 500, end: 1_300, speaker: "mic:speaker-1", track: .mic),
    ]

    let turns = TranscriptProjector.turns(from: words)

    #expect(turns.map(\.text) == ["Keep talking.", "Overlap."])
    #expect(turns[0].start_ms == 0)
    #expect(turns[1].start_ms == 500)
}

@Test func tentativeStdoutLineIsTimestampedAndMarked() {
    let turn = TranscriptDocument.Turn(
        id: "turn-1",
        utterance_id: "utterance-1",
        track: .system,
        speaker_id: "system:speaker-2",
        speaker_state: .tentative,
        start_ms: 12_000,
        end_ms: 18_000,
        text: "A tentative line.",
        word_ids: ["word-1"]
    )
    #expect(TentativeTranscriptLine.render(turn) ==
        "[0:12–0:18] system:speaker-2? A tentative line.\n")
}

private func word(
    _ text: String,
    id: String,
    start: Int,
    end: Int,
    speaker: String = "system:pending",
    track: TranscriptTrackID = .system,
    episode: String? = nil,
    window: String = "utterance-1"
) -> TranscriptDocument.Word {
    TranscriptDocument.Word(
        id: id,
        utterance_id: window,
        episode_id: episode,
        processing_window_id: window,
        track: track,
        start_ms: start,
        end_ms: end,
        text: text,
        confidence: 0.9,
        speaker_id: speaker,
        speaker_state: .pending,
        speaker_candidates: []
    )
}

private func span(
    _ speaker: String,
    start: Int,
    end: Int,
    activity: Float = 1
) -> TranscriptDocument.SpeakerSpan {
    TranscriptDocument.SpeakerSpan(
        id: "\(speaker):\(start)",
        track: .system,
        speaker_id: speaker,
        start_ms: start,
        end_ms: end,
        state: .final,
        activity: activity
    )
}
