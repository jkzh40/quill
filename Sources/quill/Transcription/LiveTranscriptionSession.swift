@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation

/// A deep copy of a recorder callback buffer. AVFoundation and Core Audio
/// reuse callback memory, so the original must not cross an async boundary.
struct CapturedAudioBuffer: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let capturedAt: Date

    init?(copying source: AVAudioPCMBuffer, capturedAt: Date = Date()) {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        copy.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            let byteCount = Int(sourceBuffer.mDataByteSize)
            guard
                byteCount <= Int(destinationBuffers[index].mDataByteSize),
                let sourceData = sourceBuffer.mData,
                let destinationData = destinationBuffers[index].mData
            else { return nil }
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffer.mDataByteSize
        }
        pcm = copy
        self.capturedAt = capturedAt
    }
}

typealias AudioBufferHandler = @Sendable (CapturedAudioBuffer) -> Void

/// Models shared by the two track processors. LS-EEND serializes predictions
/// inside its model wrapper, so two streaming sessions can safely share the
/// expensive Core ML object while retaining independent recurrent state.
struct LiveTranscriptionResources: @unchecked Sendable {
    let asrModels: AsrModels
    let vad: VadManager
    let diarizerModel: LSEENDModel?

    var provenance: TranscriptDocument.Models {
        TranscriptDocument.Models(
            asr: "parakeet-tdt-0.6b-v2-coreml",
            vad: "silero-vad-unified-256ms-v6.2.1",
            diarizer: diarizerModel == nil ? "disabled" : "ls-eend-dihard3-100ms-coreml"
        )
    }

    static func prepare(includeDiarization: Bool = true) async throws -> LiveTranscriptionResources {
        async let asr = ParakeetModelLoader.loadV2()
        async let vad = VadManager(config: VadConfig(defaultThreshold: 0.5))
        let diarizer: LSEENDModel?
        if includeDiarization {
            diarizer = try await LSEENDModel.loadFromHuggingFace(
                variant: .dihard3,
                stepSize: .step100ms
            )
        } else {
            diarizer = nil
        }
        return try await LiveTranscriptionResources(
            asrModels: asr,
            vad: vad,
            diarizerModel: diarizer
        )
    }
}

private struct SpeechClip: Sendable {
    let id: String
    let episodeID: String
    let track: TranscriptTrackID
    let startSample: Int
    let endSample: Int
    let samples: [Float]
    let forcedSplit: Bool

    var startTime: TimeInterval { TimeInterval(startSample) / 16_000 }
    var endTime: TimeInterval { TimeInterval(endSample) / 16_000 }
}

private final class SendableDiarizer: @unchecked Sendable {
    let value: LSEENDDiarizer

    init(_ value: LSEENDDiarizer) {
        self.value = value
    }
}

/// The live CLI pipeline. Each track has independent VAD and diarization state;
/// completed speech clips share one
/// serial, backpressured Parakeet worker so Core ML inference cannot race or
/// accumulate an unbounded recovery queue.
actor LiveTranscriptionSession {
    private let store: TranscriptStore
    private let stdout: TentativeTranscriptWriter?
    private let resources: LiveTranscriptionResources
    private let startedAt: Date

    private let micBuffers: AsyncStream<CapturedAudioBuffer>
    private let systemBuffers: AsyncStream<CapturedAudioBuffer>
    nonisolated private let micContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
    nonisolated private let systemContinuation: AsyncStream<CapturedAudioBuffer>.Continuation

    private var micProcessor: LiveTrackProcessor?
    private var systemProcessor: LiveTrackProcessor?
    private var transcriber: SpeechClipTranscriber?
    private var micInputTask: Task<Void, Never>?
    private var systemInputTask: Task<Void, Never>?
    private var trackStarts: [TranscriptTrackID: Date] = [:]
    private var offsetsAreFixed = false

    init(
        sessionDir: URL,
        startedAt: Date,
        resources: LiveTranscriptionResources,
        standardOutputDescriptor: Int32? = nil,
        transcriptURL: URL? = nil,
        initialStatus: TranscriptLifecycle = .recording
    ) {
        self.resources = resources
        self.startedAt = startedAt
        store = TranscriptStore(
            url: transcriptURL ?? sessionDir.appendingPathComponent("transcript.json"),
            sessionID: sessionDir.lastPathComponent,
            startedAt: startedAt,
            models: resources.provenance,
            status: initialStatus
        )
        stdout = standardOutputDescriptor.map(TentativeTranscriptWriter.init(descriptor:))
        (micBuffers, micContinuation) = AsyncStream.makeStream()
        (systemBuffers, systemContinuation) = AsyncStream.makeStream()
    }

    func prepare() async throws {
        try await store.prepare()

        let micDiarizer = try resources.diarizerModel.map { try LSEENDDiarizer(model: $0) }
        let systemDiarizer = try resources.diarizerModel.map { try LSEENDDiarizer(model: $0) }
        let manager = AsrManager()
        try await manager.loadModels(resources.asrModels)
        let transcriber = SpeechClipTranscriber(
            manager: manager,
            store: store,
            stdout: stdout
        )
        self.transcriber = transcriber
        let mic = LiveTrackProcessor(
            track: .mic,
            vad: resources.vad,
            diarizer: micDiarizer.map(SendableDiarizer.init),
            store: store,
            transcriber: transcriber
        )
        let system = LiveTrackProcessor(
            track: .system,
            vad: resources.vad,
            diarizer: systemDiarizer.map(SendableDiarizer.init),
            store: store,
            transcriber: transcriber
        )
        micProcessor = mic
        systemProcessor = system

        micInputTask = inputTask(stream: micBuffers, track: .mic, processor: mic)
        systemInputTask = inputTask(stream: systemBuffers, track: .system, processor: system)
    }

    nonisolated func receiveMic(_ buffer: CapturedAudioBuffer) {
        micContinuation.yield(buffer)
    }

    nonisolated func receiveSystem(_ buffer: CapturedAudioBuffer) {
        systemContinuation.yield(buffer)
    }

    func configureTrackOffsets(micMs: Int, systemMs: Int) async {
        offsetsAreFixed = true
        await store.setTrackOffsets([.mic: micMs, .system: systemMs])
    }

    /// Replay recorded CAF tracks through the identical live pipeline. This is
    /// used for crash recovery and intentionally writes no stdout output.
    func replay(
        mic: URL?,
        system: URL?,
        from start: TimeInterval = 0,
        to end: TimeInterval? = nil
    ) async throws {
        var firstFailure: Error?
        if let mic, let micProcessor {
            do { try await replayFile(mic, from: start, to: end, through: micProcessor) } catch {
                firstFailure = error
                await store.recordFailure(component: "recovery:mic", error: error)
            }
        }
        if let system, let systemProcessor {
            do { try await replayFile(system, from: start, to: end, through: systemProcessor) } catch {
                if firstFailure == nil { firstFailure = error }
                await store.recordFailure(component: "recovery:system", error: error)
            }
        }
        if let firstFailure { throw firstFailure }
    }

    func finish() async throws {
        try await store.setStatus(.finalizing)
        micContinuation.finish()
        systemContinuation.finish()
        await micInputTask?.value
        await systemInputTask?.value

        var firstFailure: Error?
        if let micProcessor {
            do { try await micProcessor.finish() } catch { firstFailure = error }
        }
        if let systemProcessor {
            do { try await systemProcessor.finish() } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let transcriber {
            do { try await transcriber.finish() } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        try await store.finish()
        if let firstFailure { throw firstFailure }
        try await store.checkForFailure()
    }

    func markInterrupted() async {
        try? await store.setStatus(.interrupted)
    }

    func currentDocument() async -> TranscriptDocument {
        await store.currentDocument()
    }

    private func inputTask(
        stream: AsyncStream<CapturedAudioBuffer>,
        track: TranscriptTrackID,
        processor: LiveTrackProcessor
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var first = true
            for await buffer in stream {
                if first {
                    await self?.noteTrackStart(track, at: buffer.capturedAt)
                    first = false
                }
                await processor.receive(buffer)
            }
        }
    }

    private func noteTrackStart(_ track: TranscriptTrackID, at date: Date) async {
        guard !offsetsAreFixed, trackStarts[track] == nil else { return }
        trackStarts[track] = date
        let origin = trackStarts.values.min() ?? date
        var offsets: [TranscriptTrackID: Int] = [:]
        for candidate in TranscriptTrackID.allCases {
            let start = trackStarts[candidate] ?? origin
            offsets[candidate] = Int((start.timeIntervalSince(origin) * 1000).rounded())
        }
        await store.setTrackOffsets(offsets)
    }

    private func replayFile(
        _ url: URL,
        from start: TimeInterval,
        to end: TimeInterval?,
        through processor: LiveTrackProcessor
    ) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let firstFrame = min(file.length, max(0, AVAudioFramePosition(start * format.sampleRate)))
        let lastFrame = end.map {
            min(file.length, max(firstFrame, AVAudioFramePosition($0 * format.sampleRate)))
        } ?? file.length
        file.framePosition = firstFrame
        let framesPerRead = AVAudioFrameCount(max(4096, Int(format.sampleRate / 4)))
        while file.framePosition < lastFrame {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(framesPerRead), lastFrame - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0,
                  let captured = CapturedAudioBuffer(copying: buffer, capturedAt: startedAt)
            else { break }
            await processor.receive(captured)
        }
    }
}

private actor SpeechClipTranscriber {
    private let manager: AsrManager
    private let store: TranscriptStore
    private let stdout: TentativeTranscriptWriter?
    private var reconcilers: [TranscriptTrackID: LiveWordReconciler] = [:]
    private var firstFailure: Error?

    init(
        manager: AsrManager,
        store: TranscriptStore,
        stdout: TentativeTranscriptWriter?
    ) {
        self.manager = manager
        self.store = store
        self.stdout = stdout
    }

    func process(_ clip: SpeechClip) async {
        do {
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(
                clip.samples,
                decoderState: &decoderState
            )
            var reconciler = reconcilers[clip.track] ?? LiveWordReconciler()
            let evaluation = ASRAcceptancePolicy.evaluate(
                result,
                startingAt: clip.startTime,
                reconciler: &reconciler
            )
            reconcilers[clip.track] = reconciler
            guard evaluation.status == .accepted else {
                await store.completeProcessingWindow(
                    id: clip.id,
                    status: evaluation.status,
                    confidence: result.confidence,
                    hypothesis: evaluation.hypothesis
                )
                return
            }

            let wordIDs = await store.completeProcessingWindow(
                id: clip.id,
                status: .accepted,
                confidence: result.confidence,
                hypothesis: evaluation.hypothesis,
                words: evaluation.words.map {
                    TranscriptStore.TimedWord(
                        text: $0.text,
                        start: $0.start,
                        end: $0.end,
                        confidence: $0.confidence
                    )
                }
            )
            if let stdout {
                await stdout.write(await store.previewTurns(forWordIDs: wordIDs))
            }
        } catch {
            if firstFailure == nil { firstFailure = error }
            await store.completeProcessingWindow(
                id: clip.id,
                status: .failed,
                confidence: nil,
                hypothesis: nil
            )
            await store.recordFailure(
                component: "asr:\(clip.track.rawValue)",
                error: error
            )
        }
    }

    func finish() async throws {
        await manager.cleanup()
        if let firstFailure { throw firstFailure }
    }
}

private actor LiveTrackProcessor {
    private static let sampleRate = 16_000
    private static let vadChunkSamples = 4096
    private static let maxClipSamples = TranscriptionDefaults.processingWindowMs * sampleRate / 1_000
    private static let overlapSamples = TranscriptionDefaults.processingOverlapMs * sampleRate / 1_000
    private static let inactiveHistorySamples = sampleRate
    private static let minimumSpeechSamples = Int(0.3 * Double(sampleRate))

    private let track: TranscriptTrackID
    private let vad: VadManager
    private let diarizer: SendableDiarizer?
    private let store: TranscriptStore
    private let transcriber: SpeechClipTranscriber
    private let converter = DurationCorrectingAudioConverter()
    private let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.3,
        minSilenceDuration: 0.75,
        maxSpeechDuration: .infinity,
        speechPadding: 0.1,
        silenceThresholdForSplit: 0.35,
        negativeThreshold: 0.35,
        negativeThresholdOffset: 0.15,
        minSilenceAtMaxSpeech: 0.098,
        useMaxPossibleSilenceAtMaxSpeech: true
    )

    private var vadState = VadStreamState.initial()
    private var pendingVAD: [Float] = []
    private var ring: [Float] = []
    private var ringStartSample = 0
    private var totalSamples = 0
    private var episodeID: String?
    private var episodeStartSample: Int?
    private var windowStartSample: Int?
    private var failure: Error?

    init(
        track: TranscriptTrackID,
        vad: VadManager,
        diarizer: SendableDiarizer?,
        store: TranscriptStore,
        transcriber: SpeechClipTranscriber
    ) {
        self.track = track
        self.vad = vad
        self.diarizer = diarizer
        self.store = store
        self.transcriber = transcriber
    }

    func receive(_ buffer: CapturedAudioBuffer) async {
        guard failure == nil else { return }
        do {
            let samples = try converter.convert(buffer.pcm)
            guard !samples.isEmpty else { return }
            ring.append(contentsOf: samples)
            totalSamples += samples.count

            if let diarizer, let update = try diarizer.value.process(
                samples: samples,
                sourceSampleRate: Double(Self.sampleRate)
            ) {
                await publishDiarization(update)
            }

            if let episodeID {
                await store.advanceEpisode(id: episodeID, through: sampleTime(totalSamples))
            }

            pendingVAD.append(contentsOf: samples)
            while pendingVAD.count >= Self.vadChunkSamples {
                let chunk = Array(pendingVAD.prefix(Self.vadChunkSamples))
                pendingVAD.removeFirst(Self.vadChunkSamples)
                try await processVAD(chunk)
            }
            trimRing()
        } catch {
            failure = error
            await store.recordFailure(component: "live:\(track.rawValue)", error: error)
        }
    }

    func finish() async throws {
        defer { diarizer?.value.cleanup() }
        if failure == nil, !pendingVAD.isEmpty {
            do {
                let tail = pendingVAD
                pendingVAD.removeAll()
                try await processVAD(tail)
            } catch {
                failure = error
                await store.recordFailure(component: "vad:\(track.rawValue)", error: error)
            }
        }

        if failure == nil,
           let episodeID,
           let windowStartSample
        {
            await emitClip(
                episodeID: episodeID,
                start: windowStartSample,
                end: totalSamples,
                forced: false
            )
            await store.finishEpisode(id: episodeID, at: sampleTime(totalSamples))
            clearEpisode()
        }

        if failure == nil, let diarizer {
            do {
                _ = try diarizer.value.finalizeSession()
                let timeline = diarizer.value.timeline
                let spans = timeline.speakers.values.flatMap { speaker in
                    speaker.finalizedSegments.map(Self.span)
                }
                await store.replaceDiarization(
                    track: track,
                    finalized: spans,
                    finalizedThrough: TimeInterval(timeline.duration)
                )
            } catch {
                failure = error
                await store.recordFailure(component: "diarization:\(track.rawValue)", error: error)
            }
        }
        if let failure { throw failure }
    }

    private func processVAD(_ chunk: [Float]) async throws {
        let result = try await vad.processStreamingChunk(
            chunk,
            state: vadState,
            config: segmentation
        )
        vadState = result.state
        if let event = result.event {
            switch event.kind {
            case .speechStart:
                if episodeID == nil {
                    let id = UUID().uuidString
                    episodeID = id
                    episodeStartSample = event.sampleIndex
                    windowStartSample = event.sampleIndex
                    await store.beginEpisode(
                        id: id,
                        track: track,
                        start: sampleTime(event.sampleIndex)
                    )
                }
            case .speechEnd:
                if let episodeID, let windowStartSample {
                    await emitClip(
                        episodeID: episodeID,
                        start: windowStartSample,
                        end: event.sampleIndex,
                        forced: false
                    )
                    await store.finishEpisode(id: episodeID, at: sampleTime(event.sampleIndex))
                }
                clearEpisode()
            }
        }

        while let episodeID,
              let start = windowStartSample,
              vadState.processedSamples - start >= Self.maxClipSamples
        {
            let end = start + Self.maxClipSamples
            await emitClip(episodeID: episodeID, start: start, end: end, forced: true)
            windowStartSample = end - Self.overlapSamples
            await store.advanceEpisode(id: episodeID, through: sampleTime(end))
        }
    }

    private func emitClip(
        episodeID: String,
        start requestedStart: Int,
        end requestedEnd: Int,
        forced: Bool
    ) async {
        let start = max(requestedStart, ringStartSample)
        let end = min(max(start, requestedEnd), ringStartSample + ring.count)
        guard end - start >= Self.minimumSpeechSamples else { return }
        let lower = start - ringStartSample
        let upper = end - ringStartSample
        guard lower >= 0, upper <= ring.count, lower < upper else { return }

        let clip = SpeechClip(
            id: UUID().uuidString,
            episodeID: episodeID,
            track: track,
            startSample: start,
            endSample: end,
            samples: Array(ring[lower..<upper]),
            forcedSplit: forced
        )
        await store.addProcessingWindow(
            id: clip.id,
            episodeID: episodeID,
            track: track,
            start: clip.startTime,
            end: clip.endTime,
            forcedSplit: forced
        )
        await transcriber.process(clip)
    }

    private func publishDiarization(_ update: DiarizerTimelineUpdate) async {
        guard let diarizer else { return }
        let finalized = update.finalizedSegments.map(Self.span)
        let tentative = update.tentativeSegments.map(Self.span)
        let endFrame = update.chunkResult.startFrame + update.chunkResult.finalizedFrameCount
        let seconds = TimeInterval(Float(endFrame) * diarizer.value.timeline.config.frameDurationSeconds)
        await store.applyDiarization(
            track: track,
            finalized: finalized,
            tentative: tentative,
            finalizedThrough: seconds
        )
    }

    private func trimRing() {
        let keepFrom = windowStartSample ?? max(0, totalSamples - Self.inactiveHistorySamples)
        let drop = max(0, keepFrom - ringStartSample)
        guard drop > 0 else { return }
        let actual = min(drop, ring.count)
        ring.removeFirst(actual)
        ringStartSample += actual
    }

    private func clearEpisode() {
        episodeID = nil
        episodeStartSample = nil
        windowStartSample = nil
    }

    private func sampleTime(_ sample: Int) -> TimeInterval {
        TimeInterval(sample) / TimeInterval(Self.sampleRate)
    }

    private static func span(_ segment: DiarizerSegment) -> TranscriptStore.DiarizationSpan {
        TranscriptStore.DiarizationSpan(
            speakerIndex: segment.speakerIndex,
            start: TimeInterval(segment.startTime),
            end: TimeInterval(segment.endTime),
            state: segment.isFinalized ? .final : .tentative,
            activity: segment.activity
        )
    }
}

/// Stdout is deliberately best-effort and non-authoritative. Each ASR result
/// is printed once; later speaker corrections are visible only in JSON.
private actor TentativeTranscriptWriter {
    private let descriptor: Int32
    private var failed = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ turns: [TranscriptDocument.Turn]) {
        guard !failed else { return }
        for turn in turns {
            do {
                try writeAll(Data(TentativeTranscriptLine.render(turn).utf8))
            } catch {
                failed = true
                FileHandle.standardError.write(Data("live stdout failed: \(error)\n".utf8))
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
    }
}

enum TentativeTranscriptLine {
    static func render(_ turn: TranscriptDocument.Turn) -> String {
        let tentative = turn.speaker_state != .final
        return "[\(clock(turn.start_ms))–\(clock(turn.end_ms))] "
            + "\(turn.speaker_id)\(tentative ? "?" : "") \(turn.text)\n"
    }

    private static func clock(_ milliseconds: Int) -> String {
        let total = max(0, milliseconds / 1000)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// FluidAudio's one-buffer converter is intentionally stateless. Capture tap
/// sizes rarely divide evenly into 16 kHz, so independently rounding every
/// callback can accumulate seconds of timestamp drift over a long meeting.
/// Correct each result to the cumulative source duration while retaining the
/// library's format conversion and channel mixing.
private final class DurationCorrectingAudioConverter: @unchecked Sendable {
    private let converter = AudioConverter()
    private var expectedSampleCount: Double = 0
    private var emittedSampleCount = 0

    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        var converted = try converter.resampleBuffer(buffer)
        expectedSampleCount += Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate
        let expectedTotal = Int(expectedSampleCount.rounded())
        let required = max(0, expectedTotal - emittedSampleCount)

        if converted.count > required {
            converted.removeLast(converted.count - required)
        } else if converted.count < required {
            converted.append(
                contentsOf: repeatElement(converted.last ?? 0, count: required - converted.count)
            )
        }
        emittedSampleCount += converted.count
        return converted
    }
}

struct RecognizedWord: Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float
}

struct ASRAcceptance: Equatable, Sendable {
    let status: TranscriptASRStatus
    let confidence: Float
    let hypothesis: String?
    let words: [RecognizedWord]
}

enum ASRAcceptancePolicy {
    static func evaluate(
        _ result: ASRResult,
        startingAt offset: TimeInterval,
        reconciler: inout LiveWordReconciler
    ) -> ASRAcceptance {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hypothesis = text.isEmpty ? nil : text
        if text.isEmpty, result.tokenTimings?.isEmpty != false {
            return ASRAcceptance(
                status: .empty,
                confidence: result.confidence,
                hypothesis: nil,
                words: []
            )
        }
        guard result.confidence >= TranscriptionDefaults.minimumASRConfidence else {
            return ASRAcceptance(
                status: .lowConfidence,
                confidence: result.confidence,
                hypothesis: hypothesis,
                words: []
            )
        }
        let timed = buildConfidentWordTimings(from: result.tokenTimings ?? []).map {
            RecognizedWord(
                text: $0.text,
                start: offset + $0.start,
                end: offset + $0.end,
                confidence: $0.confidence
            )
        }
        guard !timed.isEmpty else {
            return ASRAcceptance(
                status: .missingTimings,
                confidence: result.confidence,
                hypothesis: hypothesis,
                words: []
            )
        }
        let accepted = reconciler.accept(timed)
        return ASRAcceptance(
            status: accepted.isEmpty ? .duplicatesOnly : .accepted,
            confidence: result.confidence,
            hypothesis: hypothesis,
            words: accepted
        )
    }
}

/// FluidAudio intentionally omits confidence from its public word timing type.
/// Aggregate the same SentencePiece groups while retaining the mean token
/// confidence needed by the durable word stream.
func buildConfidentWordTimings(from tokenTimings: [TokenTiming]) -> [RecognizedWord] {
    var words: [RecognizedWord] = []
    var text = ""
    var start: TimeInterval = 0
    var end: TimeInterval = 0
    var confidenceTotal: Float = 0
    var tokenCount = 0

    func flush() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, tokenCount > 0 else { return }
        words.append(RecognizedWord(
            text: trimmed,
            start: start,
            end: end,
            confidence: confidenceTotal / Float(tokenCount)
        ))
    }

    for timing in tokenTimings {
        let token = timing.token
        guard !token.isEmpty, token != "<blank>", token != "<pad>" else { continue }
        let startsNewWord = token.hasPrefix("▁")
            || token.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) == true
            || text.isEmpty
        if startsNewWord, !text.isEmpty {
            flush()
            text = ""
            confidenceTotal = 0
            tokenCount = 0
        }
        if startsNewWord {
            text = String(token.drop(while: { $0 == "▁" || $0.isWhitespace }))
            start = timing.startTime
        } else {
            text += token
        }
        end = timing.endTime
        confidenceTotal += timing.confidence
        tokenCount += 1
    }
    flush()
    return words
}

/// Suppresses only identical words referring to the same moment. This handles
/// the two-second overlap used when VAD force-splits uninterrupted speech.
struct LiveWordReconciler {
    private static let historySeconds: TimeInterval = 5
    private var recent: [RecognizedWord] = []
    private var latestEnd: TimeInterval = 0

    mutating func accept(_ words: [RecognizedWord]) -> [RecognizedWord] {
        var accepted: [RecognizedWord] = []
        for word in words.sorted(by: Self.isEarlier) {
            let candidates = recent + accepted
            guard !candidates.contains(where: { Self.isSameTimedWord($0, word) }) else { continue }
            accepted.append(word)
            latestEnd = max(latestEnd, word.end)
        }
        recent += accepted
        recent.removeAll { $0.end < latestEnd - Self.historySeconds }
        return accepted
    }

    private static func isEarlier(_ lhs: RecognizedWord, _ rhs: RecognizedWord) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }

    private static func isSameTimedWord(_ lhs: RecognizedWord, _ rhs: RecognizedWord) -> Bool {
        guard normalized(lhs.text) == normalized(rhs.text) else { return false }
        let lhsStart = milliseconds(lhs.start)
        let lhsEnd = milliseconds(lhs.end)
        let rhsStart = milliseconds(rhs.start)
        let rhsEnd = milliseconds(rhs.end)
        let overlap = min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart)
        let shorter = min(lhsEnd - lhsStart, rhsEnd - rhsStart)
        if shorter > 0, overlap * 2 >= shorter { return true }
        return abs(lhsStart - rhsStart) <= 80
            && abs(lhsEnd - rhsEnd) <= 80
    }

    private static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1_000).rounded())
    }
}
