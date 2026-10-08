import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// plus a meta.json that is created before capture begins and updated on stop.
/// Creating metadata up front makes an interrupted session discoverable by the
/// recovery scanner even when the process never reaches `stop()`.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private var mic: MicRecorder
    private var system: SystemAudioRecorder
    private let transcriptionEnabled: Bool

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(
        root: URL,
        transcriptionEnabled: Bool = Config.transcriptionEnabled(),
        onMicBuffer: AudioBufferHandler? = nil,
        onSystemBuffer: AudioBufferHandler? = nil
    ) throws {
        self.transcriptionEnabled = transcriptionEnabled
        mic = MicRecorder(onBuffer: onMicBuffer)
        system = SystemAudioRecorder(onBuffer: onSystemBuffer)

        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        try writeMeta(status: "recording", endedAt: nil)
    }

    /// Attach live consumers after the session directory exists but before
    /// capture starts. The live store needs that directory for transcript.json.
    func setBufferHandlers(
        mic onMicBuffer: AudioBufferHandler?,
        system onSystemBuffer: AudioBufferHandler?
    ) {
        precondition(!mic.isRecording && !system.isRecording)
        mic = MicRecorder(onBuffer: onMicBuffer)
        system = SystemAudioRecorder(onBuffer: onSystemBuffer)
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop both tracks and atomically mark meta.json complete.
    func stop() {
        mic.stop()
        system.stop()

        try? writeMeta(status: "complete", endedAt: Date())
    }

    /// Offsets on the shared session clock, available once first buffers have
    /// arrived. Missing/silent tracks begin at the session origin.
    var trackOffsetsMs: [TranscriptTrackID: Int] {
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        return [
            .mic: Int((micStart.timeIntervalSince(earliest) * 1000).rounded()),
            .system: Int((systemStart.timeIntervalSince(earliest) * 1000).rounded()),
        ]
    }

    private func writeMeta(status: String, endedAt: Date?) throws {
        let iso = ISO8601DateFormatter()
        var meta: [String: Any] = [
            "schema_version": 1,
            "status": status,
            "started": iso.string(from: startedAt),
            "transcription_enabled": transcriptionEnabled,
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": trackOffsetsMs[.mic] ?? 0,
                "system": trackOffsetsMs[.system] ?? 0,
            ],
        ]
        if let endedAt {
            meta["ended"] = iso.string(from: endedAt)
            meta["duration_seconds"] = Int(endedAt.timeIntervalSince(startedAt))
        }
        let data = try JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}
