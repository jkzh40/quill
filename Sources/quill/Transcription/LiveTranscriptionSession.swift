@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation

/// A deep copy of a recorder callback buffer. AVFoundation reuses its callback
/// buffers, so the original must never cross into an asynchronous transcriber.
struct CapturedAudioBuffer: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let capturedAt: Date

    init?(copying source: AVAudioPCMBuffer) {
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
        capturedAt = Date()
    }
}

typealias AudioBufferHandler = @Sendable (CapturedAudioBuffer) -> Void

private enum LiveTrack: CaseIterable, Hashable, Sendable {
    case mic
    case system

    var speaker: String {
        switch self {
        case .mic: return "me"
        case .system: return "them"
        }
    }
}

/// Runs two streaming Parakeet decoders over the same buffers that are being
/// recorded to disk. Updates are serialized through one append-only writer;
/// the normal post-recording transcript remains separate and canonical.
actor LiveTranscriptionSession {
    private static let chunkSeconds: TimeInterval = 11

    private let output: LiveTranscriptCoordinator
    private let micBuffers: AsyncStream<CapturedAudioBuffer>
    private let systemBuffers: AsyncStream<CapturedAudioBuffer>
    nonisolated private let micContinuation: AsyncStream<CapturedAudioBuffer>.Continuation
    nonisolated private let systemContinuation: AsyncStream<CapturedAudioBuffer>.Continuation

    private var micManager: SlidingWindowAsrManager?
    private var systemManager: SlidingWindowAsrManager?
    private var micInputTask: Task<Void, Never>?
    private var systemInputTask: Task<Void, Never>?
    private var micOutputTask: Task<Void, Never>?
    private var systemOutputTask: Task<Void, Never>?

    init(output: URL) {
        self.output = LiveTranscriptCoordinator(url: output)
        (micBuffers, micContinuation) = AsyncStream.makeStream()
        (systemBuffers, systemContinuation) = AsyncStream.makeStream()
    }

    /// Load the already-configured v2 model before capture starts so the first
    /// words aren't lost while Core ML initializes. Both streams share models.
    func prepare() async throws {
        try await output.prepare()
        let models = try await ParakeetModelLoader.loadV2()
        // The same proven 2 s left + 11 s center + 2 s right context used by
        // FluidAudio's high-quality sliding-window path. Unlike the previous
        // five-second low-latency setup, this favors canonical-like output.
        let config = SlidingWindowAsrConfig.default.applying(
            tdtConfig: TdtConfig(blankId: AsrModelVersion.v2.blankId)
        )

        let mic = SlidingWindowAsrManager(config: config)
        let system = SlidingWindowAsrManager(config: config)
        try await mic.loadModels(models)
        try await system.loadModels(models)
        try await mic.startStreaming(source: .microphone)
        try await system.startStreaming(source: .system)

        let micUpdates = await mic.transcriptionUpdates
        let systemUpdates = await system.transcriptionUpdates
        micOutputTask = outputTask(updates: micUpdates, track: .mic)
        systemOutputTask = outputTask(updates: systemUpdates, track: .system)
        micInputTask = inputTask(buffers: micBuffers, manager: mic, track: .mic)
        systemInputTask = inputTask(buffers: systemBuffers, manager: system, track: .system)
        micManager = mic
        systemManager = system
    }

    /// These synchronous entry points are safe in audio callbacks: AsyncStream
    /// continuations are thread-safe and preserve each track's yield order.
    nonisolated func receiveMic(_ buffer: CapturedAudioBuffer) {
        micContinuation.yield(buffer)
    }

    nonisolated func receiveSystem(_ buffer: CapturedAudioBuffer) {
        systemContinuation.yield(buffer)
    }

    /// Drain every captured buffer, flush each decoder's final partial chunk,
    /// then close the update streams only after their appended output is read.
    func finish() async throws {
        micContinuation.finish()
        systemContinuation.finish()
        await micInputTask?.value
        await systemInputTask?.value

        guard let micManager, let systemManager else { return }
        let micFinish = Task { try await micManager.finish() }
        let systemFinish = Task { try await systemManager.finish() }

        var transcriptionFailure: Error?
        do { _ = try await micFinish.value } catch { transcriptionFailure = error }
        do { _ = try await systemFinish.value } catch {
            if transcriptionFailure == nil { transcriptionFailure = error }
        }

        await micManager.cancel()
        await systemManager.cancel()
        await micOutputTask?.value
        await systemOutputTask?.value
        await micManager.cleanup()
        await systemManager.cleanup()

        try await output.checkForFailure()
        if let transcriptionFailure { throw transcriptionFailure }
    }

    private func inputTask(
        buffers: AsyncStream<CapturedAudioBuffer>,
        manager: SlidingWindowAsrManager,
        track: LiveTrack
    ) -> Task<Void, Never> {
        Task { [output] in
            var first = true
            for await buffer in buffers {
                if first {
                    await output.noteStart(of: track, at: buffer.capturedAt)
                    first = false
                }
                await manager.streamAudio(buffer.pcm)
            }
        }
    }

    private func outputTask(
        updates: AsyncStream<SlidingWindowTranscriptionUpdate>,
        track: LiveTrack
    ) -> Task<Void, Never> {
        Task { [output] in
            var reconciler = LiveWordReconciler()
            var segmenter = IncrementalTranscriptSegmenter()
            var processedWindows = 0
            for await update in updates {
                processedWindows += 1
                let decoded = buildWordTimings(from: update.tokenTimings)
                let segments = segmenter.append(reconciler.accept(decoded))
                await output.receive(
                    segments,
                    from: track,
                    processedThrough: TimeInterval(processedWindows) * Self.chunkSeconds,
                    openSegmentStart: segmenter.openStart
                )
            }
            if let final = segmenter.finish() {
                await output.receive(
                    [final],
                    from: track,
                    processedThrough: TimeInterval(processedWindows) * Self.chunkSeconds,
                    openSegmentStart: nil
                )
            }
            await output.finish(track)
        }
    }
}

/// Suppresses only duplicate words that refer to the same moment in the audio.
/// FluidAudio already reconciles token IDs across most sliding-window seams;
/// this timing check covers residual updates without guessing whether a spoken
/// repetition at a later timestamp was intentional.
struct LiveWordReconciler {
    private static let historySeconds: TimeInterval = 5

    private var recent: [WordTiming] = []
    private var latestEnd: TimeInterval = 0

    mutating func accept(_ words: [WordTiming]) -> [WordTiming] {
        var accepted: [WordTiming] = []
        for word in words.sorted(by: Self.isEarlier) {
            let candidates = recent + accepted
            guard !candidates.contains(where: { Self.isSameTimedWord($0, word) }) else {
                continue
            }
            accepted.append(word)
            latestEnd = max(latestEnd, word.endTime)
        }

        recent += accepted
        let cutoff = latestEnd - Self.historySeconds
        recent.removeAll { $0.endTime < cutoff }
        return accepted
    }

    private static func isEarlier(_ lhs: WordTiming, _ rhs: WordTiming) -> Bool {
        if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
        return lhs.endTime < rhs.endTime
    }

    private static func isSameTimedWord(_ lhs: WordTiming, _ rhs: WordTiming) -> Bool {
        guard normalized(lhs.word) == normalized(rhs.word) else { return false }
        let overlap = min(lhs.endTime, rhs.endTime) - max(lhs.startTime, rhs.startTime)
        let shorterDuration = min(
            max(0, lhs.endTime - lhs.startTime),
            max(0, rhs.endTime - rhs.startTime)
        )
        if shorterDuration > 0, overlap / shorterDuration >= 0.5 { return true }

        // Very short punctuation timings can shift by a frame and have too
        // little duration for a useful overlap ratio.
        return shorterDuration <= 0.05
            && abs(lhs.startTime - rhs.startTime) <= 0.05
    }

    private static func normalized(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        if !scalars.isEmpty { return String(String.UnicodeScalarView(scalars)) }
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds completed segments until both decoders have advanced far enough that
/// no earlier segment can still arrive. Track-relative model timestamps are
/// shifted onto the same clock using the first captured buffer from each track.
private actor LiveTranscriptCoordinator {
    private struct PendingSegment {
        let track: LiveTrack
        let relativeStart: TimeInterval
        let relativeEnd: TimeInterval
        let text: String
    }

    private let writer: LiveTranscriptWriter
    private var starts: [LiveTrack: Date] = [:]
    private var processedThrough: [LiveTrack: TimeInterval] = [:]
    private var openSegmentStarts: [LiveTrack: TimeInterval] = [:]
    private var finished: Set<LiveTrack> = []
    private var pending: [PendingSegment] = []
    private var turnAssembler = TranscriptTurnAssembler()

    init(url: URL) {
        writer = LiveTranscriptWriter(url: url)
    }

    func prepare() async throws {
        try await writer.prepare()
    }

    func noteStart(of track: LiveTrack, at date: Date) async {
        if starts[track] == nil { starts[track] = date }
        await flushReady()
    }

    func receive(
        _ segments: [TranscriptSegment],
        from track: LiveTrack,
        processedThrough newProgress: TimeInterval,
        openSegmentStart: TimeInterval?
    ) async {
        pending += segments.map {
            PendingSegment(
                track: track,
                relativeStart: $0.start,
                relativeEnd: $0.end,
                text: $0.text
            )
        }
        processedThrough[track] = max(processedThrough[track] ?? 0, newProgress)
        if let openSegmentStart {
            openSegmentStarts[track] = openSegmentStart
        } else {
            openSegmentStarts.removeValue(forKey: track)
        }
        await flushReady()
    }

    func finish(_ track: LiveTrack) async {
        if starts[track] == nil {
            starts[track] = starts.values.min() ?? Date()
        }
        openSegmentStarts.removeValue(forKey: track)
        finished.insert(track)
        await flushReady()
    }

    func checkForFailure() async throws {
        try await writer.checkForFailure()
    }

    private func flushReady() async {
        guard let origin = starts.values.min(), starts.count == LiveTrack.allCases.count else {
            return
        }

        let safeThrough: TimeInterval
        if finished.count == LiveTrack.allCases.count {
            safeThrough = .infinity
        } else {
            var watermarks: [TimeInterval] = []
            for track in LiveTrack.allCases {
                if finished.contains(track) {
                    watermarks.append(.infinity)
                    continue
                }
                guard let progress = processedThrough[track], let start = starts[track] else {
                    return
                }
                let relativeSafe = min(progress, openSegmentStarts[track] ?? .infinity)
                watermarks.append(start.timeIntervalSince(origin) + relativeSafe)
            }
            safeThrough = watermarks.min() ?? 0
        }

        var ready: [PendingSegment] = []
        var waiting: [PendingSegment] = []
        for segment in pending {
            if alignedStart(of: segment, origin: origin) <= safeThrough {
                ready.append(segment)
            } else {
                waiting.append(segment)
            }
        }
        pending = waiting
        ready.sort {
            let lhs = alignedStart(of: $0, origin: origin)
            let rhs = alignedStart(of: $1, origin: origin)
            if lhs != rhs { return lhs < rhs }
            return $0.track.speaker < $1.track.speaker
        }

        for segment in ready {
            guard let trackStart = starts[segment.track] else { continue }
            let offset = trackStart.timeIntervalSince(origin)
            let completed = turnAssembler.append(SpeakerTranscriptSegment(
                speaker: segment.track.speaker,
                start: offset + segment.relativeStart,
                end: offset + segment.relativeEnd,
                text: segment.text
            ))
            for turn in completed {
                await writer.append(turn)
            }
        }
        if let completed = turnAssembler.advance(to: safeThrough) {
            await writer.append(completed)
        }
    }

    private func alignedStart(of segment: PendingSegment, origin: Date) -> TimeInterval {
        guard let trackStart = starts[segment.track] else { return .infinity }
        return trackStart.timeIntervalSince(origin) + segment.relativeStart
    }
}

/// Appends complete Markdown paragraphs without ever reading or rewriting the
/// destination. The path is reopened for every chunk with O_APPEND so editor
/// changes are ignored and the next chunk targets the file currently at path.
private actor LiveTranscriptWriter {
    private let url: URL
    private var failure: Error?

    init(url: URL) {
        self.url = url
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try appendData(Data())
    }

    func append(_ turn: TranscriptTurn) {
        guard failure == nil else { return }
        let paragraph = "\(TranscriptTurnMarkdown.block(turn))\n\n"
        do {
            try appendData(Data(paragraph.utf8))
        } catch {
            failure = error
            FileHandle.standardError.write(Data(
                "live transcript write failed: \(error)\n".utf8
            ))
        }
    }

    func checkForFailure() throws {
        if let failure { throw failure }
    }

    private func appendData(_ data: Data) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard !data.isEmpty else { return }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: written),
                    bytes.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
    }
}
