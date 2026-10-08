import Foundation

enum TranscriptTrackID: String, Codable, CaseIterable, Hashable, Sendable {
    case mic
    case system
}

enum TranscriptLifecycle: String, Codable, Sendable {
    case recording
    case recovering
    case finalizing
    case complete
    case failed
    case interrupted
}

enum TranscriptEvidenceState: String, Codable, Sendable {
    case pending
    case tentative
    case final
    case unknown
}

enum TranscriptEpisodeState: String, Codable, Sendable {
    case open
    case final
}

enum TranscriptASRStatus: String, Codable, Sendable {
    case pending
    case accepted
    case empty
    case lowConfidence = "low_confidence"
    case missingTimings = "missing_timings"
    case duplicatesOnly = "duplicates_only"
    case failed
}

enum TranscriptionDefaults {
    static let minimumASRConfidence: Float = 0.65
    static let processingWindowMs = 14_000
    static let processingOverlapMs = 2_000
    static let turnGapMs = 2_000

    static let policy = TranscriptDocument.TranscriptionPolicy(
        minimum_asr_confidence: minimumASRConfidence,
        processing_window_ms: processingWindowMs,
        processing_overlap_ms: processingOverlapMs,
        turn_gap_ms: turnGapMs
    )
}

struct TranscriptDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    struct Models: Codable, Equatable, Sendable {
        let asr: String
        let vad: String
        let diarizer: String
    }

    struct TranscriptionPolicy: Codable, Equatable, Sendable {
        let minimum_asr_confidence: Float
        let processing_window_ms: Int
        let processing_overlap_ms: Int
        let turn_gap_ms: Int
    }

    struct Track: Codable, Equatable, Sendable {
        let id: TranscriptTrackID
        let file: String
        var start_offset_ms: Int
    }

    struct Speaker: Codable, Equatable, Sendable {
        let id: String
        let track: TranscriptTrackID
        let index: Int
        var name: String?
    }

    /// Compatibility view of an ASR processing window. New consumers should
    /// use `processing_windows`, whose relationship to a VAD episode is explicit.
    struct Utterance: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let track: TranscriptTrackID
        let start_ms: Int
        let end_ms: Int
        let forced_split: Bool
    }

    struct Episode: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let track: TranscriptTrackID
        let start_ms: Int
        let end_ms: Int
        let state: TranscriptEpisodeState
    }

    struct ProcessingWindow: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let episode_id: String
        let track: TranscriptTrackID
        let start_ms: Int
        let end_ms: Int
        let forced_split: Bool
        let asr_status: TranscriptASRStatus
        let asr_confidence: Float?
        let hypothesis_text: String?
        let accepted_word_ids: [String]
    }

    struct SpeakerCandidate: Codable, Equatable, Sendable {
        let speaker_id: String
        let overlap_ms: Int
        let activity: Float
        let state: TranscriptEvidenceState
    }

    struct Word: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let utterance_id: String
        let episode_id: String?
        let processing_window_id: String?
        let track: TranscriptTrackID
        let start_ms: Int
        let end_ms: Int
        let text: String
        let confidence: Float?
        let speaker_id: String
        let speaker_state: TranscriptEvidenceState
        let speaker_candidates: [SpeakerCandidate]

        init(
            id: String,
            utterance_id: String,
            episode_id: String? = nil,
            processing_window_id: String? = nil,
            track: TranscriptTrackID,
            start_ms: Int,
            end_ms: Int,
            text: String,
            confidence: Float? = nil,
            speaker_id: String,
            speaker_state: TranscriptEvidenceState,
            speaker_candidates: [SpeakerCandidate]
        ) {
            self.id = id
            self.utterance_id = utterance_id
            self.episode_id = episode_id
            self.processing_window_id = processing_window_id
            self.track = track
            self.start_ms = start_ms
            self.end_ms = end_ms
            self.text = text
            self.confidence = confidence
            self.speaker_id = speaker_id
            self.speaker_state = speaker_state
            self.speaker_candidates = speaker_candidates
        }
    }

    struct SpeakerSpan: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let track: TranscriptTrackID
        let speaker_id: String
        let start_ms: Int
        let end_ms: Int
        let state: TranscriptEvidenceState
        let activity: Float
    }

    struct Turn: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let utterance_id: String
        let episode_ids: [String]
        let processing_window_ids: [String]
        let track: TranscriptTrackID
        let speaker_id: String
        let speaker_state: TranscriptEvidenceState
        let start_ms: Int
        let end_ms: Int
        let text: String
        let word_ids: [String]

        init(
            id: String,
            utterance_id: String,
            episode_ids: [String] = [],
            processing_window_ids: [String] = [],
            track: TranscriptTrackID,
            speaker_id: String,
            speaker_state: TranscriptEvidenceState,
            start_ms: Int,
            end_ms: Int,
            text: String,
            word_ids: [String]
        ) {
            self.id = id
            self.utterance_id = utterance_id
            self.episode_ids = episode_ids
            self.processing_window_ids = processing_window_ids
            self.track = track
            self.speaker_id = speaker_id
            self.speaker_state = speaker_state
            self.start_ms = start_ms
            self.end_ms = end_ms
            self.text = text
            self.word_ids = word_ids
        }

        private enum CodingKeys: String, CodingKey {
            case id, utterance_id, episode_ids, processing_window_ids, track
            case speaker_id, speaker_state, start_ms, end_ms, text, word_ids
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            utterance_id = try values.decode(String.self, forKey: .utterance_id)
            episode_ids = try values.decodeIfPresent([String].self, forKey: .episode_ids) ?? []
            processing_window_ids = try values.decodeIfPresent(
                [String].self,
                forKey: .processing_window_ids
            ) ?? [utterance_id]
            track = try values.decode(TranscriptTrackID.self, forKey: .track)
            speaker_id = try values.decode(String.self, forKey: .speaker_id)
            speaker_state = try values.decode(TranscriptEvidenceState.self, forKey: .speaker_state)
            start_ms = try values.decode(Int.self, forKey: .start_ms)
            end_ms = try values.decode(Int.self, forKey: .end_ms)
            text = try values.decode(String.self, forKey: .text)
            word_ids = try values.decode([String].self, forKey: .word_ids)
        }
    }

    struct Issue: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let created_at: String
        let component: String
        let message: String
    }

    let schema_version: Int
    let revision: Int
    let session_id: String
    let status: TranscriptLifecycle
    let started_at: String
    let updated_at: String
    let completed_at: String?
    let models: Models
    let transcription_policy: TranscriptionPolicy?
    let tracks: [Track]
    let speakers: [Speaker]
    let utterances: [Utterance]
    let episodes: [Episode]
    let processing_windows: [ProcessingWindow]
    let words: [Word]
    let speaker_spans: [SpeakerSpan]
    let turns: [Turn]
    let errors: [Issue]

    init(
        schema_version: Int,
        revision: Int,
        session_id: String,
        status: TranscriptLifecycle,
        started_at: String,
        updated_at: String,
        completed_at: String?,
        models: Models,
        transcription_policy: TranscriptionPolicy? = nil,
        tracks: [Track],
        speakers: [Speaker],
        utterances: [Utterance],
        episodes: [Episode] = [],
        processing_windows: [ProcessingWindow] = [],
        words: [Word],
        speaker_spans: [SpeakerSpan],
        turns: [Turn],
        errors: [Issue]
    ) {
        self.schema_version = schema_version
        self.revision = revision
        self.session_id = session_id
        self.status = status
        self.started_at = started_at
        self.updated_at = updated_at
        self.completed_at = completed_at
        self.models = models
        self.transcription_policy = transcription_policy
        self.tracks = tracks
        self.speakers = speakers
        self.utterances = utterances
        self.episodes = episodes
        self.processing_windows = processing_windows
        self.words = words
        self.speaker_spans = speaker_spans
        self.turns = turns
        self.errors = errors
    }

    private enum CodingKeys: String, CodingKey {
        case schema_version, revision, session_id, status, started_at, updated_at, completed_at
        case models, transcription_policy, tracks, speakers, utterances, episodes
        case processing_windows, words, speaker_spans, turns, errors
    }

    /// Schema v2 is additive: a full v1 document remains decodable and receives
    /// empty/default values for fields that did not exist when it was written.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try values.decode(Int.self, forKey: .schema_version)
        revision = try values.decode(Int.self, forKey: .revision)
        session_id = try values.decode(String.self, forKey: .session_id)
        status = try values.decode(TranscriptLifecycle.self, forKey: .status)
        started_at = try values.decode(String.self, forKey: .started_at)
        updated_at = try values.decode(String.self, forKey: .updated_at)
        completed_at = try values.decodeIfPresent(String.self, forKey: .completed_at)
        models = try values.decode(Models.self, forKey: .models)
        transcription_policy = try values.decodeIfPresent(
            TranscriptionPolicy.self,
            forKey: .transcription_policy
        )
        tracks = try values.decode([Track].self, forKey: .tracks)
        speakers = try values.decode([Speaker].self, forKey: .speakers)
        utterances = try values.decode([Utterance].self, forKey: .utterances)
        episodes = try values.decodeIfPresent([Episode].self, forKey: .episodes) ?? []
        processing_windows = try values.decodeIfPresent(
            [ProcessingWindow].self,
            forKey: .processing_windows
        ) ?? []
        words = try values.decode([Word].self, forKey: .words)
        speaker_spans = try values.decode([SpeakerSpan].self, forKey: .speaker_spans)
        turns = try values.decode([Turn].self, forKey: .turns)
        errors = try values.decode([Issue].self, forKey: .errors)
    }
}

/// A pure projection from immutable ASR words plus replaceable diarization
/// evidence. Persistence and streaming code never incrementally edits turns.
enum TranscriptProjector {
    static let maximumTurnGapMs = TranscriptionDefaults.turnGapMs

    static func projectWords(
        _ words: [TranscriptDocument.Word],
        spans: [TranscriptDocument.SpeakerSpan],
        finalizedThroughMs: [TranscriptTrackID: Int]
    ) -> [TranscriptDocument.Word] {
        let spansByTrack = Dictionary(grouping: spans, by: \.track)
        return words.map { word in
            let candidates = (spansByTrack[word.track] ?? []).compactMap { span -> TranscriptDocument.SpeakerCandidate? in
                let overlap = min(word.end_ms, span.end_ms) - max(word.start_ms, span.start_ms)
                guard overlap > 0 else { return nil }
                return TranscriptDocument.SpeakerCandidate(
                    speaker_id: span.speaker_id,
                    overlap_ms: overlap,
                    activity: span.activity,
                    state: span.state
                )
            }.sorted {
                if $0.overlap_ms != $1.overlap_ms { return $0.overlap_ms > $1.overlap_ms }
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return $0.speaker_id < $1.speaker_id
            }

            let selected = candidates.first
            let finalizedThrough = finalizedThroughMs[word.track] ?? 0
            let state: TranscriptEvidenceState
            let speakerID: String
            if let selected {
                state = selected.state
                speakerID = selected.speaker_id
            } else if word.end_ms <= finalizedThrough {
                state = .unknown
                speakerID = "\(word.track.rawValue):unknown"
            } else {
                state = .pending
                speakerID = "\(word.track.rawValue):pending"
            }

            return TranscriptDocument.Word(
                id: word.id,
                utterance_id: word.utterance_id,
                episode_id: word.episode_id,
                processing_window_id: word.processing_window_id,
                track: word.track,
                start_ms: word.start_ms,
                end_ms: word.end_ms,
                text: word.text,
                confidence: word.confidence,
                speaker_id: speakerID,
                speaker_state: state,
                speaker_candidates: candidates
            )
        }.sorted(by: wordOrder)
    }

    /// Forms independent speaker lanes first, then orders the resulting turns
    /// globally. This keeps overlapping speakers as overlapping turns instead
    /// of fragmenting both lanes each time their individual words interleave.
    static func turns(
        from words: [TranscriptDocument.Word],
        maximumGapMs: Int = maximumTurnGapMs
    ) -> [TranscriptDocument.Turn] {
        let ordered = words.sorted(by: wordOrder)
        let lanes = Dictionary(grouping: ordered) { word in
            SpeakerLane(track: word.track, speakerID: word.speaker_id)
        }
        var turns: [TranscriptDocument.Turn] = []

        for laneWords in lanes.values {
            var current: [TranscriptDocument.Word] = []

            func flush() {
                guard let turn = makeTurn(current) else {
                    current.removeAll(keepingCapacity: true)
                    return
                }
                turns.append(turn)
                current.removeAll(keepingCapacity: true)
            }

            for word in laneWords.sorted(by: wordOrder) {
                if let previous = current.last {
                    let gap = word.start_ms - previous.end_ms
                    let hasInterveningSpeaker = gap > 0 && ordered.contains { other in
                        guard other.track != word.track || other.speaker_id != word.speaker_id else {
                            return false
                        }
                        let reachesIntoGap = other.end_ms > previous.end_ms
                            && other.start_ms < word.start_ms
                        let doesNotOverlapBothSides = other.start_ms >= previous.end_ms
                            || other.end_ms <= word.start_ms
                        return reachesIntoGap && doesNotOverlapBothSides
                    }
                    if gap > maximumGapMs || hasInterveningSpeaker { flush() }
                }
                current.append(word)
            }
            flush()
        }

        return turns.sorted {
            if $0.start_ms != $1.start_ms { return $0.start_ms < $1.start_ms }
            if $0.end_ms != $1.end_ms { return $0.end_ms < $1.end_ms }
            return $0.id < $1.id
        }
    }

    private struct SpeakerLane: Hashable {
        let track: TranscriptTrackID
        let speakerID: String
    }

    private static func makeTurn(
        _ words: [TranscriptDocument.Word]
    ) -> TranscriptDocument.Turn? {
        guard let first = words.first else { return nil }
        let text = render(words.map(\.text))
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return nil
        }
        let episodeIDs = unique(words.compactMap(\.episode_id))
        let windowIDs = unique(words.map { $0.processing_window_id ?? $0.utterance_id })
        return TranscriptDocument.Turn(
            id: first.id,
            utterance_id: windowIDs.first ?? first.utterance_id,
            episode_ids: episodeIDs,
            processing_window_ids: windowIDs,
            track: first.track,
            speaker_id: first.speaker_id,
            speaker_state: leastFinalState(in: words),
            start_ms: first.start_ms,
            end_ms: max(first.start_ms, words.map(\.end_ms).max() ?? first.end_ms),
            text: text,
            word_ids: words.map(\.id)
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func wordOrder(
        _ lhs: TranscriptDocument.Word,
        _ rhs: TranscriptDocument.Word
    ) -> Bool {
        if lhs.start_ms != rhs.start_ms { return lhs.start_ms < rhs.start_ms }
        if lhs.end_ms != rhs.end_ms { return lhs.end_ms < rhs.end_ms }
        return lhs.id < rhs.id
    }

    private static func leastFinalState(
        in words: [TranscriptDocument.Word]
    ) -> TranscriptEvidenceState {
        if words.contains(where: { $0.speaker_state == .pending }) { return .pending }
        if words.contains(where: { $0.speaker_state == .tentative }) { return .tentative }
        if words.contains(where: { $0.speaker_state == .unknown }) { return .unknown }
        return .final
    }

    private static func render(_ pieces: [String]) -> String {
        let boundaryPunctuation = CharacterSet(charactersIn: ".,;:!?")
        var text = ""
        for piece in pieces {
            let word = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let punctuationOnly = word.unicodeScalars.allSatisfy(boundaryPunctuation.contains)
            if text.isEmpty {
                text = word
            } else if punctuationOnly {
                if let last = text.unicodeScalars.last, boundaryPunctuation.contains(last) {
                    continue
                }
                text += word
            } else {
                text += " \(word)"
            }
        }
        return text
    }
}
