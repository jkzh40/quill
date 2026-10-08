import ArgumentParser
import Darwin
import Foundation

@main
struct Quill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local CLI meeting recorder with live, on-device transcription.",
        subcommands: [Record.self, Doctor.self],
        defaultSubcommand: Record.self
    )
}

/// Record one meeting from the command line. Capture starts after model
/// preparation, VAD-completed speech streams to stdout, and Ctrl-C stops the
/// recording before transcript.json is finalized.
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record and stream a live transcript until Ctrl-C."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(name: .long, help: "Record audio only; do not load speech models or write a transcript.")
    var noTranscribe = false

    mutating func run() async throws {
        let root = Config.resolveRoot(cliOverride: out)
        let shouldTranscribe = !noTranscribe && Config.transcriptionEnabled()
        try await Self.runHeadless(
            root: root,
            shouldTranscribe: shouldTranscribe
        )
    }

    @MainActor
    private static func runHeadless(
        root: URL,
        shouldTranscribe: Bool
    ) async throws {
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.printToStandardError(checks)
            throw ExitCode(1)
        }

        let coordinator = TranscriptionCoordinator()
        let resources: LiveTranscriptionResources?
        if shouldTranscribe {
            FileHandle.standardError.write(Data("preparing speech models…\n".utf8))
            // This happens before a RecordingSession exists: a missing model
            // or failed download must never start an untranscribed recording.
            resources = try await coordinator.prepareResources()
            signal(SIGPIPE, SIG_IGN)
            await coordinator.setStatusHandler { status in
                let message: String?
                switch status {
                case .idle:
                    message = nil
                case .recovering(let name, let queued):
                    message = queued > 0
                        ? "recovering \(name) · \(queued) queued\n"
                        : "recovering \(name)\n"
                case .failed(let name):
                    message = "recovery failed · \(name)\n"
                }
                if let message { FileHandle.standardError.write(Data(message.utf8)) }
            }
            await coordinator.resumePending(root: root)
        } else {
            resources = nil
            FileHandle.standardError.write(Data("transcription disabled · audio only\n".utf8))
        }

        let session = try RecordingSession(
            root: root,
            transcriptionEnabled: shouldTranscribe
        )
        let live: LiveTranscriptionSession?
        if let resources {
            let pipeline = LiveTranscriptionSession(
                sessionDir: session.dir,
                startedAt: session.startedAt,
                resources: resources,
                standardOutputDescriptor: STDOUT_FILENO
            )
            try await pipeline.prepare()
            session.setBufferHandlers(
                mic: { buffer in pipeline.receiveMic(buffer) },
                system: { buffer in pipeline.receiveSystem(buffer) }
            )
            live = pipeline
            FileHandle.standardError.write(Data(
                "transcript → stdout + \(session.dir.appendingPathComponent("transcript.json").path)\n".utf8
            ))
        } else {
            live = nil
        }
        try session.start()
        FileHandle.standardError.write(Data(
            "● recording → \(session.dir.path) · Ctrl-C to stop\n".utf8
        ))

        await waitForInterrupt()
        session.stop()

        let elapsed = format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))

        if let live {
            await live.configureTrackOffsets(
                micMs: session.trackOffsetsMs[.mic] ?? 0,
                systemMs: session.trackOffsetsMs[.system] ?? 0
            )
            try await live.finish()
            await coordinator.completed(session.dir)
            FileHandle.standardError.write(Data("transcript finalized\n".utf8))
        } else {
            await coordinator.completedAudioOnly(session.dir)
        }
        await coordinator.waitUntilIdle()
    }

    /// Suspend without blocking the main actor until the user interrupts the
    /// recording. Restore SIGINT's default action afterward so a second
    /// Ctrl-C can abort finalization.
    private static func waitForInterrupt() async {
        signal(SIGINT, SIG_IGN)
        await withCheckedContinuation { continuation in
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            source.setEventHandler {
                source.cancel()
                continuation.resume()
            }
            source.resume()
        }
        signal(SIGINT, SIG_DFL)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, system audio, recordings folder, and models."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}
