import AVFoundation
import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v2 (English) via FluidAudio's Core ML port. Models
/// download once into FluidAudio's managed cache (~600 MB); after that,
/// transcription runs entirely on-device at roughly 20 seconds per hour of
/// audio on Apple Silicon.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model = "parakeet-tdt-0.6b-v2-coreml"

    private var manager: AsrManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let models = try await ParakeetModelLoader.loadV2()
        let manager = AsrManager()
        try await manager.loadModels(models)
        self.manager = manager
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let manager else { throw EngineError.notPrepared }

        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? []
                : [TranscriptSegment(start: 0, end: result.duration, text: text)]
        }
        return TranscriptSegmenter.segments(from: words)
    }

    func release() async {
        if let manager { await manager.cleanup() }
        manager = nil
    }
}

/// The word-to-segment policy shared by canonical and live transcription.
/// Keeping this in one place makes the live Markdown use the same sentence,
/// silence-gap, and length boundaries as the final transcript.
enum TranscriptSegmenter {
    static func segments(from words: [WordTiming]) -> [TranscriptSegment] {
        var segmenter = IncrementalTranscriptSegmenter()
        var out = segmenter.append(words)
        if let final = segmenter.finish() { out.append(final) }
        return out
    }
}

/// Stateful form of `TranscriptSegmenter` for word timings that arrive one
/// decoded window at a time. It intentionally keeps an unfinished sentence
/// across window boundaries instead of emitting punctuation-only fragments.
struct IncrementalTranscriptSegmenter {
    private var current: [WordTiming] = []

    var openStart: TimeInterval? { current.first?.startTime }

    mutating func append(_ words: [WordTiming]) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0,
               let segment = flush()
            {
                out.append(segment)
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if (endsSentence || current.count >= 60), let segment = flush() {
                out.append(segment)
            }
        }
        return out
    }

    mutating func finish() -> TranscriptSegment? {
        flush()
    }

    private mutating func flush() -> TranscriptSegment? {
        guard let first = current.first, let last = current.last else { return nil }
        defer { current = [] }
        let text = Self.render(current)
        // Parakeet occasionally emits a second bare period at a sliding-window
        // seam. It carries no spoken content and cannot usefully stand alone in
        // either the canonical or append-only live transcript.
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            return nil
        }
        return TranscriptSegment(
            start: first.startTime,
            end: last.endTime,
            text: text
        )
    }

    /// FluidAudio usually includes punctuation on the word, but a seam token
    /// can be just ".". Attach such tokens to an open sentence without adding
    /// the otherwise visible space before punctuation.
    private static func render(_ words: [WordTiming]) -> String {
        var text = ""
        for timing in words {
            let word = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            let hasAlphanumeric = word.unicodeScalars.contains(
                where: CharacterSet.alphanumerics.contains
            )
            if text.isEmpty {
                text = word
            } else if hasAlphanumeric {
                text += " \(word)"
            } else {
                text += word
            }
        }
        return text
    }
}
