import Foundation
import Testing
@testable import quill

@Test func storeAtomicallyMirrorsMutableStateAsOneJSONDocument() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-store-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("transcript.json")
    let store = TranscriptStore(
        url: url,
        sessionID: "meeting",
        startedAt: Date(timeIntervalSince1970: 0),
        models: .init(asr: "asr", vad: "vad", diarizer: "diarizer")
    )

    try await store.prepare()
    await store.beginEpisode(
        id: "episode-1",
        track: .mic,
        start: 1
    )
    await store.addProcessingWindow(
        id: "utterance-1",
        episodeID: "episode-1",
        track: .mic,
        start: 1,
        end: 2,
        forcedSplit: false
    )
    await store.completeProcessingWindow(
        id: "utterance-1",
        status: .accepted,
        confidence: 0.95,
        hypothesis: "Hello.",
        words: [.init(text: "Hello.", start: 1, end: 2, confidence: 0.95)]
    )
    await store.finishEpisode(id: "episode-1", at: 2)
    await store.applyDiarization(
        track: .mic,
        finalized: [
            .init(speakerIndex: 0, start: 0.9, end: 2.1, state: .final, activity: 0.9),
            .init(speakerIndex: 0, start: 2.5, end: 3, state: .final, activity: 0.8),
        ],
        tentative: [],
        finalizedThrough: 2.1
    )
    try await store.finish()

    let decoded = try JSONDecoder().decode(
        TranscriptDocument.self,
        from: Data(contentsOf: url)
    )
    #expect(decoded.schema_version == 2)
    #expect(decoded.status == .complete)
    #expect(decoded.words.count == 1)
    #expect(decoded.words[0].episode_id == "episode-1")
    #expect(decoded.words[0].confidence == 0.95)
    #expect(decoded.words[0].speaker_id == "mic:speaker-1")
    #expect(decoded.turns.map(\.text) == ["Hello."])
    #expect(decoded.episodes.map(\.id) == ["episode-1"])
    #expect(decoded.processing_windows.map(\.id) == ["utterance-1"])
    #expect(decoded.processing_windows[0].accepted_word_ids == [decoded.words[0].id])
    #expect(decoded.utterances.map(\.id) == ["utterance-1"])
    #expect(decoded.speaker_spans.count == 2)
    #expect(decoded.speakers.count == 1)
}

@Test func recoveryRecognizesIncompleteAndLegacyDocuments() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-recovery-test-\(UUID().uuidString)")
    let incomplete = root.appendingPathComponent("incomplete")
    let legacy = root.appendingPathComponent("legacy")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let meta = Data(#"{"started":"2026-01-01T00:00:00Z","files":{"mic":"mic.caf"}}"#.utf8)
    try meta.write(to: incomplete.appendingPathComponent("meta.json"))
    try meta.write(to: legacy.appendingPathComponent("meta.json"))
    try Data(#"{"schema_version":1,"status":"recording"}"#.utf8)
        .write(to: incomplete.appendingPathComponent("transcript.json"))
    try Data(#"{"engine":"parakeet","segments":[]}"#.utf8)
        .write(to: legacy.appendingPathComponent("transcript.json"))

    #expect(SessionRecovery.needsRecovery(incomplete))
    #expect(!SessionRecovery.needsRecovery(legacy))
}

@Test func recordingMetadataExistsBeforeCaptureAndCanDisableRecovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("quill-session-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let session = try RecordingSession(root: root, transcriptionEnabled: false)
    let data = try Data(contentsOf: session.dir.appendingPathComponent("meta.json"))
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(json["status"] as? String == "recording")
    #expect(json["transcription_enabled"] as? Bool == false)
    #expect(!SessionRecovery.needsRecovery(session.dir))
}
