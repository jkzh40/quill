import Foundation
import Testing
@testable import quill

private let localRegressionSession = ProcessInfo.processInfo.environment["QUILL_REGRESSION_SESSION"]
private let runFullLocalRegression = ProcessInfo.processInfo.environment["QUILL_REGRESSION_FULL"] == "1"
private let debugRegressionDuplicates = ProcessInfo.processInfo.environment[
    "QUILL_REGRESSION_DEBUG_DUPLICATES"
] == "1"

@Suite("Local session regression", .serialized)
struct LocalSessionRegression {
    @Test(.enabled(if: localRegressionSession != nil))
    func curatedStructuralFixtures() async throws {
        let session = URL(fileURLWithPath: try #require(localRegressionSession), isDirectory: true)
        let manifest = try loadManifest()
        let resources = try await LiveTranscriptionResources.prepare(includeDiarization: false)
        var metrics: [FixtureMetrics] = []

        for fixture in manifest.fixtures {
            let document = try await replay(fixture, from: session, resources: resources)
            validateReferences(document, fixture: fixture)
            let result = FixtureMetrics(fixture: fixture, document: document)
            validateFixture(result, document: document, fixture: fixture)
            metrics.append(result)
        }

        try writeReport(
            RegressionReport(baseline: manifest.baseline, fixtures: metrics),
            name: "curated"
        )
    }

    @Test(.enabled(if: localRegressionSession != nil && runFullLocalRegression))
    func fullSessionStructuralReport() async throws {
        let session = URL(fileURLWithPath: try #require(localRegressionSession), isDirectory: true)
        let manifest = try loadManifest()
        let resources = try await LiveTranscriptionResources.prepare(includeDiarization: false)
        let fixture = RegressionFixture(
            id: "full-session",
            kind: .full,
            start_seconds: 0,
            end_seconds: nil,
            tracks: [.mic, .system]
        )
        let document = try await replay(fixture, from: session, resources: resources)
        validateReferences(document, fixture: fixture)
        let metrics = FixtureMetrics(fixture: fixture, document: document)
        #expect(metrics.overlapping_duplicate_words == 0)
        #expect(metrics.invalid_turn_boundaries == 0)
        try writeReport(
            RegressionReport(baseline: manifest.baseline, fixtures: [metrics]),
            name: "full"
        )
    }

    private func replay(
        _ fixture: RegressionFixture,
        from session: URL,
        resources: LiveTranscriptionResources
    ) async throws -> TranscriptDocument {
        let fileManager = FileManager.default
        let output = fileManager.temporaryDirectory
            .appendingPathComponent("quill-regression-\(fixture.id)-\(UUID().uuidString)")
        try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: output) }

        let mic = fixture.tracks.contains(.mic)
            ? session.appendingPathComponent("mic.caf")
            : nil
        let system = fixture.tracks.contains(.system)
            ? session.appendingPathComponent("system.caf")
            : nil
        if let mic { #expect(fileManager.fileExists(atPath: mic.path)) }
        if let system { #expect(fileManager.fileExists(atPath: system.path)) }

        let pipeline = LiveTranscriptionSession(
            sessionDir: output,
            startedAt: Date(timeIntervalSince1970: 0),
            resources: resources
        )
        try await pipeline.prepare()
        await pipeline.configureTrackOffsets(micMs: 0, systemMs: 0)
        try await pipeline.replay(
            mic: mic,
            system: system,
            from: fixture.start_seconds,
            to: fixture.end_seconds
        )
        try await pipeline.finish()
        return await pipeline.currentDocument()
    }

    private func validateFixture(
        _ metrics: FixtureMetrics,
        document: TranscriptDocument,
        fixture: RegressionFixture
    ) {
        #expect(metrics.overlapping_duplicate_words == 0, "\(fixture.id) duplicated timed words")
        #expect(metrics.invalid_turn_boundaries == 0, "\(fixture.id) retained a window-only turn boundary")

        switch fixture.kind {
        case .forcedOverlap:
            #expect(metrics.processing_windows >= 2, "\(fixture.id) did not cross an ASR window")
            #expect(metrics.words > 0, "\(fixture.id) lost all speech")
            let windowsByEpisode = Dictionary(
                grouping: document.processing_windows,
                by: \.episode_id
            )
            #expect(
                windowsByEpisode.values.contains { $0.count >= 2 },
                "\(fixture.id) did not preserve an episode across ASR windows"
            )
        case .silence:
            #expect(metrics.words == 0, "\(fixture.id) promoted a quiet-tail hypothesis")
            #expect(metrics.turns == 0)
        case .speech:
            #expect(metrics.words > 0, "\(fixture.id) lost the short-speech control")
        case .crossTrack:
            #expect(Set(document.words.map(\.track)) == Set(fixture.tracks))
        case .full:
            break
        }
    }

    private func validateReferences(
        _ document: TranscriptDocument,
        fixture: RegressionFixture
    ) {
        #expect(document.schema_version == 2)
        #expect(document.status == .complete)
        #expect(document.transcription_policy == TranscriptionDefaults.policy)
        #expect(Set(document.utterances.map(\.id)) == Set(document.processing_windows.map(\.id)))

        let episodes = Dictionary(uniqueKeysWithValues: document.episodes.map { ($0.id, $0) })
        let windows = Dictionary(uniqueKeysWithValues: document.processing_windows.map { ($0.id, $0) })
        let words = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0) })
        #expect(document.episodes.allSatisfy { $0.state == .final })

        for window in document.processing_windows {
            #expect(episodes[window.episode_id]?.track == window.track)
            let actualWordIDs = document.words
                .filter { $0.processing_window_id == window.id }
                .map(\.id)
            #expect(Set(actualWordIDs) == Set(window.accepted_word_ids))
            if window.asr_status == .accepted {
                #expect(window.asr_confidence ?? 0 >= TranscriptionDefaults.minimumASRConfidence)
                #expect(!window.accepted_word_ids.isEmpty)
            } else {
                #expect(window.accepted_word_ids.isEmpty)
            }
        }

        for word in document.words {
            #expect(word.confidence != nil)
            #expect((word.confidence ?? -1) >= 0 && (word.confidence ?? 2) <= 1)
            #expect(word.processing_window_id == word.utterance_id)
            #expect(windows[word.processing_window_id ?? ""]?.episode_id == word.episode_id)
            #expect(episodes[word.episode_id ?? ""]?.track == word.track)
        }

        for turn in document.turns {
            #expect(turn.word_ids.allSatisfy { words[$0] != nil })
            let turnWords = turn.word_ids.compactMap { words[$0] }
            #expect(turn.episode_ids == unique(turnWords.compactMap(\.episode_id)))
            #expect(turn.processing_window_ids == unique(
                turnWords.map { $0.processing_window_id ?? $0.utterance_id }
            ))
        }

        #expect(document.errors.isEmpty, "\(fixture.id) recorded pipeline errors")
    }

    private func loadManifest() throws -> RegressionManifest {
        let url = try #require(Bundle.module.url(
            forResource: "additional-routes-structural",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(RegressionManifest.self, from: Data(contentsOf: url))
    }

    private func writeReport(_ report: RegressionReport, name: String) throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/quill-regression", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: directory.appendingPathComponent("\(name).json"),
            options: .atomic
        )

        var markdown = "# Quill \(name) structural regression\n\n"
        markdown += "No audio or transcript text is included in this report.\n\n"
        markdown += "| Fixture | Episodes | Windows | Words | Turns | Quarantined | Duplicates | Invalid turn boundaries |\n"
        markdown += "|---|---:|---:|---:|---:|---:|---:|---:|\n"
        for fixture in report.fixtures {
            markdown += "| \(fixture.id) | \(fixture.episodes) | \(fixture.processing_windows)"
                + " | \(fixture.words) | \(fixture.turns) | \(fixture.quarantined_windows)"
                + " | \(fixture.overlapping_duplicate_words) | \(fixture.invalid_turn_boundaries) |\n"
        }
        try Data(markdown.utf8).write(
            to: directory.appendingPathComponent("\(name).md"),
            options: .atomic
        )
    }
}

private struct RegressionManifest: Decodable {
    let baseline: BaselineMetrics
    let fixtures: [RegressionFixture]
}

private struct BaselineMetrics: Codable {
    let legacy_utterances: Int
    let words: Int
    let turns: Int
    let one_word_turns: Int
    let forced_windows: Int
    let window_only_turn_boundaries: Int
}

private struct RegressionFixture: Codable {
    enum Kind: String, Codable {
        case forcedOverlap = "forced_overlap"
        case silence
        case speech
        case crossTrack = "cross_track"
        case full
    }

    let id: String
    let kind: Kind
    let start_seconds: Double
    let end_seconds: Double?
    let tracks: [TranscriptTrackID]
}

private struct RegressionReport: Codable {
    let baseline: BaselineMetrics
    let fixtures: [FixtureMetrics]
}

private struct FixtureMetrics: Codable {
    let id: String
    let kind: RegressionFixture.Kind
    let episodes: Int
    let processing_windows: Int
    let accepted_windows: Int
    let quarantined_windows: Int
    let words: Int
    let turns: Int
    let one_word_turns: Int
    let overlapping_duplicate_words: Int
    let invalid_turn_boundaries: Int
    let window_statuses: [String: Int]

    init(fixture: RegressionFixture, document: TranscriptDocument) {
        id = fixture.id
        kind = fixture.kind
        episodes = document.episodes.count
        processing_windows = document.processing_windows.count
        accepted_windows = document.processing_windows.count { $0.asr_status == .accepted }
        quarantined_windows = document.processing_windows.count {
            $0.asr_status == .lowConfidence || $0.asr_status == .missingTimings
        }
        words = document.words.count
        turns = document.turns.count
        one_word_turns = document.turns.count { $0.word_ids.count == 1 }
        overlapping_duplicate_words = Self.duplicateCount(document.words)
        invalid_turn_boundaries = Self.invalidTurnBoundaryCount(document)
        window_statuses = Dictionary(grouping: document.processing_windows, by: {
            $0.asr_status.rawValue
        }).mapValues(\.count)
    }

    private static func duplicateCount(_ words: [TranscriptDocument.Word]) -> Int {
        let groups = Dictionary(grouping: words) { word in
            let normalized = String(
                word.text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)
            )
            return "\(word.track.rawValue):\(normalized)"
        }
        var count = 0
        for (key, group) in groups where key.last != ":" {
            let sorted = group.sorted { $0.start_ms < $1.start_ms }
            for (index, word) in sorted.enumerated() {
                for other in sorted.dropFirst(index + 1) where other.start_ms < word.end_ms {
                    let overlap = min(word.end_ms, other.end_ms) - max(word.start_ms, other.start_ms)
                    let shorter = min(word.end_ms - word.start_ms, other.end_ms - other.start_ms)
                    if shorter > 0, Double(overlap) / Double(shorter) >= 0.5 {
                        count += 1
                        if debugRegressionDuplicates {
                            let sameWindow = word.processing_window_id == other.processing_window_id
                            print(
                                "duplicate track=\(word.track.rawValue) "
                                    + "a=\(word.start_ms)-\(word.end_ms) "
                                    + "b=\(other.start_ms)-\(other.end_ms) "
                                    + "ratio=\(Double(overlap) / Double(shorter)) "
                                    + "same_window=\(sameWindow)"
                            )
                        }
                    }
                }
            }
        }
        return count
    }

    private static func invalidTurnBoundaryCount(_ document: TranscriptDocument) -> Int {
        let wordsByID = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0) })
        let lanes = Dictionary(grouping: document.turns) { "\($0.track.rawValue):\($0.speaker_id)" }
        var invalid = 0
        for turns in lanes.values {
            let sorted = turns.sorted { $0.start_ms < $1.start_ms }
            for pair in zip(sorted, sorted.dropFirst()) {
                let gap = pair.1.start_ms - pair.0.end_ms
                guard gap <= TranscriptionDefaults.turnGapMs else { continue }
                let leftEnd = pair.0.word_ids.compactMap { wordsByID[$0]?.end_ms }.max() ?? pair.0.end_ms
                let rightStart = pair.1.word_ids.compactMap { wordsByID[$0]?.start_ms }.min() ?? pair.1.start_ms
                let hasInterveningSpeaker = document.words.contains { word in
                    guard word.track != pair.0.track || word.speaker_id != pair.0.speaker_id else {
                        return false
                    }
                    let reachesIntoGap = word.end_ms > leftEnd && word.start_ms < rightStart
                    let doesNotOverlapBoth = word.start_ms >= leftEnd || word.end_ms <= rightStart
                    return reachesIntoGap && doesNotOverlapBoth
                }
                if !hasInterveningSpeaker { invalid += 1 }
            }
        }
        return invalid
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
}
