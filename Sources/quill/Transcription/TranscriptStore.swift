import Foundation

actor TranscriptStore {
    struct TimedWord: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let confidence: Float
    }

    struct DiarizationSpan: Sendable {
        let speakerIndex: Int
        let start: TimeInterval
        let end: TimeInterval
        let state: TranscriptEvidenceState
        let activity: Float
    }

    private struct RawEpisode: Sendable {
        let id: String
        let track: TranscriptTrackID
        let startMs: Int
        var endMs: Int
        var state: TranscriptEpisodeState
    }

    private struct RawProcessingWindow: Sendable {
        let id: String
        let episodeID: String
        let track: TranscriptTrackID
        let startMs: Int
        let endMs: Int
        let forcedSplit: Bool
        var asrStatus: TranscriptASRStatus
        var asrConfidence: Float?
        var hypothesisText: String?
        var acceptedWordIDs: [String]
    }

    private struct RawWord: Sendable {
        let id: String
        let episodeID: String
        let processingWindowID: String
        let track: TranscriptTrackID
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Float
    }

    private struct RawSpan: Sendable {
        let id: String
        let track: TranscriptTrackID
        let speakerIndex: Int
        let startMs: Int
        let endMs: Int
        let state: TranscriptEvidenceState
        let activity: Float
    }

    private let url: URL
    private let sessionID: String
    private let startedAt: Date
    private let models: TranscriptDocument.Models
    private let encoder: JSONEncoder
    private let minimumWriteInterval: Duration

    private var revision = 0
    private var status: TranscriptLifecycle
    private var completedAt: Date?
    private var trackOffsets: [TranscriptTrackID: Int] = [.mic: 0, .system: 0]
    private var episodes: [RawEpisode] = []
    private var processingWindows: [RawProcessingWindow] = []
    private var words: [RawWord] = []
    private var finalizedSpans: [RawSpan] = []
    private var tentativeSpans: [RawSpan] = []
    private var finalizedThrough: [TranscriptTrackID: Int] = [:]
    private var issues: [TranscriptDocument.Issue] = []
    private var scheduledWrite: Task<Void, Never>?
    private var writeFailure: Error?

    init(
        url: URL,
        sessionID: String,
        startedAt: Date,
        models: TranscriptDocument.Models,
        status: TranscriptLifecycle = .recording,
        minimumWriteInterval: Duration = .milliseconds(250)
    ) {
        self.url = url
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.models = models
        self.status = status
        self.minimumWriteInterval = minimumWriteInterval
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    deinit {
        scheduledWrite?.cancel()
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try persistNow()
    }

    func setTrackOffsets(_ offsets: [TranscriptTrackID: Int]) {
        guard offsets != trackOffsets else { return }
        trackOffsets = offsets
        changed()
    }

    func beginEpisode(
        id: String,
        track: TranscriptTrackID,
        start: TimeInterval
    ) {
        guard !episodes.contains(where: { $0.id == id }) else { return }
        let startMs = milliseconds(start)
        episodes.append(RawEpisode(
            id: id,
            track: track,
            startMs: startMs,
            endMs: startMs,
            state: .open
        ))
        changed()
    }

    func advanceEpisode(id: String, through end: TimeInterval) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        let endMs = milliseconds(end)
        guard episodes[index].state == .open, endMs > episodes[index].endMs else { return }
        episodes[index].endMs = endMs
        changed()
    }

    func finishEpisode(id: String, at end: TimeInterval) {
        guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[index].endMs = max(episodes[index].startMs, milliseconds(end))
        episodes[index].state = .final
        changed()
    }

    func addProcessingWindow(
        id: String,
        episodeID: String,
        track: TranscriptTrackID,
        start: TimeInterval,
        end: TimeInterval,
        forcedSplit: Bool
    ) {
        guard !processingWindows.contains(where: { $0.id == id }) else { return }
        processingWindows.append(RawProcessingWindow(
            id: id,
            episodeID: episodeID,
            track: track,
            startMs: milliseconds(start),
            endMs: milliseconds(end),
            forcedSplit: forcedSplit,
            asrStatus: .pending,
            asrConfidence: nil,
            hypothesisText: nil,
            acceptedWordIDs: []
        ))
        changed()
    }

    /// Atomically records the diagnostic ASR result and any words promoted to
    /// the durable stream. Returns the new word IDs for best-effort stdout.
    @discardableResult
    func completeProcessingWindow(
        id: String,
        status: TranscriptASRStatus,
        confidence: Float?,
        hypothesis: String?,
        words newWords: [TimedWord] = []
    ) -> [String] {
        guard let windowIndex = processingWindows.firstIndex(where: { $0.id == id }) else {
            return []
        }
        let window = processingWindows[windowIndex]
        var acceptedIDs: [String] = []
        for word in newWords {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let wordID = UUID().uuidString
            acceptedIDs.append(wordID)
            words.append(RawWord(
                id: wordID,
                episodeID: window.episodeID,
                processingWindowID: window.id,
                track: window.track,
                startMs: milliseconds(word.start),
                endMs: milliseconds(max(word.start, word.end)),
                text: text,
                confidence: word.confidence
            ))
        }
        processingWindows[windowIndex].asrStatus = status
        processingWindows[windowIndex].asrConfidence = confidence
        processingWindows[windowIndex].hypothesisText = hypothesis
        processingWindows[windowIndex].acceptedWordIDs = acceptedIDs
        changed()
        return acceptedIDs
    }

    func applyDiarization(
        track: TranscriptTrackID,
        finalized newFinalized: [DiarizationSpan],
        tentative newTentative: [DiarizationSpan],
        finalizedThrough seconds: TimeInterval
    ) {
        for span in newFinalized {
            let raw = rawSpan(span, track: track, forcedState: .final)
            if let index = finalizedSpans.firstIndex(where: { $0.id == raw.id }) {
                finalizedSpans[index] = raw
            } else {
                finalizedSpans.append(raw)
            }
        }
        tentativeSpans.removeAll { $0.track == track }
        tentativeSpans += newTentative.map { rawSpan($0, track: track, forcedState: .tentative) }
        finalizedThrough[track] = max(finalizedThrough[track] ?? 0, milliseconds(seconds))
        changed()
    }

    func replaceDiarization(
        track: TranscriptTrackID,
        finalized spans: [DiarizationSpan],
        finalizedThrough seconds: TimeInterval
    ) {
        finalizedSpans.removeAll { $0.track == track }
        tentativeSpans.removeAll { $0.track == track }
        finalizedSpans += spans.map { rawSpan($0, track: track, forcedState: .final) }
        finalizedThrough[track] = milliseconds(seconds)
        changed()
    }

    func recordFailure(component: String, error: Error) {
        issues.append(TranscriptDocument.Issue(
            id: UUID().uuidString,
            created_at: Self.timestamp(Date()),
            component: component,
            message: String(describing: error)
        ))
        status = .failed
        changed(immediate: true)
    }

    func setStatus(_ newStatus: TranscriptLifecycle) throws {
        status = newStatus
        if newStatus == .complete { completedAt = Date() }
        revision += 1
        try persistNow()
    }

    func finish() throws {
        status = issues.isEmpty ? .complete : .failed
        if status == .complete { completedAt = Date() }
        revision += 1
        try persistNow()
        if let writeFailure { throw writeFailure }
    }

    func currentDocument() -> TranscriptDocument {
        makeDocument(updatedAt: Date())
    }

    func previewTurns(forWordIDs ids: [String]) -> [TranscriptDocument.Turn] {
        guard !ids.isEmpty else { return [] }
        let selected = Set(ids)
        let document = makeDocument(updatedAt: Date())
        return TranscriptProjector.turns(from: document.words.filter { selected.contains($0.id) })
    }

    func checkForFailure() throws {
        if let writeFailure { throw writeFailure }
    }

    private func changed(immediate: Bool = false) {
        revision += 1
        if immediate {
            do { try persistNow() } catch { writeFailure = error }
            return
        }
        guard scheduledWrite == nil else { return }
        scheduledWrite = Task { [minimumWriteInterval] in
            try? await Task.sleep(for: minimumWriteInterval)
            guard !Task.isCancelled else { return }
            self.flushScheduledWrite()
        }
    }

    private func flushScheduledWrite() {
        scheduledWrite = nil
        do { try persistNow() } catch { writeFailure = error }
    }

    private func persistNow() throws {
        scheduledWrite?.cancel()
        scheduledWrite = nil
        let data = try encoder.encode(makeDocument(updatedAt: Date()))
        try data.write(to: url, options: .atomic)
        writeFailure = nil
    }

    private func makeDocument(updatedAt: Date) -> TranscriptDocument {
        let tracks = TranscriptTrackID.allCases.map {
            TranscriptDocument.Track(
                id: $0,
                file: "\($0.rawValue).caf",
                start_offset_ms: trackOffsets[$0] ?? 0
            )
        }
        let projectedEpisodes = episodes.map { episode in
            let offset = trackOffsets[episode.track] ?? 0
            return TranscriptDocument.Episode(
                id: episode.id,
                track: episode.track,
                start_ms: episode.startMs + offset,
                end_ms: episode.endMs + offset,
                state: episode.state
            )
        }.sorted { ($0.start_ms, $0.id) < ($1.start_ms, $1.id) }
        let projectedWindows = processingWindows.map { window in
            let offset = trackOffsets[window.track] ?? 0
            return TranscriptDocument.ProcessingWindow(
                id: window.id,
                episode_id: window.episodeID,
                track: window.track,
                start_ms: window.startMs + offset,
                end_ms: window.endMs + offset,
                forced_split: window.forcedSplit,
                asr_status: window.asrStatus,
                asr_confidence: window.asrConfidence,
                hypothesis_text: window.hypothesisText,
                accepted_word_ids: window.acceptedWordIDs
            )
        }.sorted { ($0.start_ms, $0.id) < ($1.start_ms, $1.id) }
        let legacyUtterances = projectedWindows.map { window in
            TranscriptDocument.Utterance(
                id: window.id,
                track: window.track,
                start_ms: window.start_ms,
                end_ms: window.end_ms,
                forced_split: window.forced_split
            )
        }

        let unattributedWords = words.map { word in
            let offset = trackOffsets[word.track] ?? 0
            return TranscriptDocument.Word(
                id: word.id,
                utterance_id: word.processingWindowID,
                episode_id: word.episodeID,
                processing_window_id: word.processingWindowID,
                track: word.track,
                start_ms: word.startMs + offset,
                end_ms: word.endMs + offset,
                text: word.text,
                confidence: word.confidence,
                speaker_id: "\(word.track.rawValue):pending",
                speaker_state: .pending,
                speaker_candidates: []
            )
        }
        let spans = (finalizedSpans + tentativeSpans).map { span in
            let offset = trackOffsets[span.track] ?? 0
            return TranscriptDocument.SpeakerSpan(
                id: span.id,
                track: span.track,
                speaker_id: speakerID(track: span.track, index: span.speakerIndex),
                start_ms: span.startMs + offset,
                end_ms: span.endMs + offset,
                state: span.state,
                activity: span.activity
            )
        }.sorted { ($0.start_ms, $0.speaker_id) < ($1.start_ms, $1.speaker_id) }
        let globalFinalizedThrough = Dictionary(uniqueKeysWithValues: finalizedThrough.map {
            ($0.key, $0.value + (trackOffsets[$0.key] ?? 0))
        })
        let projectedWords = TranscriptProjector.projectWords(
            unattributedWords,
            spans: spans,
            finalizedThroughMs: globalFinalizedThrough
        )
        let speakerPairs = Dictionary(grouping: spans, by: \.speaker_id).mapValues { matches in
            let first = matches[0]
            return (first.track, speakerIndex(from: first.speaker_id))
        }
        let speakers = speakerPairs.values.map { track, index in
            TranscriptDocument.Speaker(
                id: speakerID(track: track, index: index),
                track: track,
                index: index,
                name: nil
            )
        }.sorted { $0.id < $1.id }

        return TranscriptDocument(
            schema_version: TranscriptDocument.currentSchemaVersion,
            revision: revision,
            session_id: sessionID,
            status: status,
            started_at: Self.timestamp(startedAt),
            updated_at: Self.timestamp(updatedAt),
            completed_at: completedAt.map(Self.timestamp),
            models: models,
            transcription_policy: TranscriptionDefaults.policy,
            tracks: tracks,
            speakers: speakers,
            utterances: legacyUtterances,
            episodes: projectedEpisodes,
            processing_windows: projectedWindows,
            words: projectedWords,
            speaker_spans: spans,
            turns: TranscriptProjector.turns(from: projectedWords),
            errors: issues
        )
    }

    private func rawSpan(
        _ span: DiarizationSpan,
        track: TranscriptTrackID,
        forcedState: TranscriptEvidenceState
    ) -> RawSpan {
        let start = milliseconds(span.start)
        let end = milliseconds(max(span.start, span.end))
        return RawSpan(
            id: "\(track.rawValue):\(span.speakerIndex):\(start)",
            track: track,
            speakerIndex: span.speakerIndex,
            startMs: start,
            endMs: end,
            state: forcedState,
            activity: span.activity
        )
    }

    private func speakerID(track: TranscriptTrackID, index: Int) -> String {
        "\(track.rawValue):speaker-\(index + 1)"
    }

    private func speakerIndex(from id: String) -> Int {
        guard let suffix = id.split(separator: "-").last, let oneBased = Int(suffix) else { return 0 }
        return max(0, oneBased - 1)
    }

    private func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((max(0, seconds) * 1000).rounded())
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
