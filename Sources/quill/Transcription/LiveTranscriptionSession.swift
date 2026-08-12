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
            var segmenter = IncrementalTranscriptSegmenter()
            var processedWindows = 0
            for await update in updates {
                processedWindows += 1
                let segments = segmenter.append(buildWordTimings(from: update.tokenTimings))
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
            await writer.append(
                speaker: segment.track.speaker,
                start: offset + segment.relativeStart,
                end: offset + segment.relativeEnd,
                text: segment.text
            )
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

    func append(speaker: String, start: TimeInterval, end: TimeInterval, text: String) {
        guard failure == nil else { return }
        let singleLine = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return }

        let clock = "[\(Self.clock(start))–\(Self.clock(max(start, end)))]"
        let paragraph = "**\(clock) \(speaker):** \(singleLine)\n\n"
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

    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
