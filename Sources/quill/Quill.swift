import AppKit
import ArgumentParser
import Foundation

@main
struct Quill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quill",
        abstract: "Local meeting recorder + transcriber. Records mic and system audio as two tracks, then transcribes on-device.",
        subcommands: [Run.self, Record.self, Doctor.self, Install.self],
        defaultSubcommand: Run.self
    )
}

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu-bar daemon (default)."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    mutating func run() async throws {
        let root = Config.resolveRoot(cliOverride: out)
        try await MainActor.run { try Self.runMain(root: root) }
    }

    @MainActor
    private static func runMain(root: URL) throws {
        // Non-blocking: permissions prompt on first recording, so warnings at
        // startup are informational, not fatal.
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = AppController(root: root)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { controller.shutdown() }
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

/// Record one meeting without creating an NSApplication or menu-bar item.
/// Capture starts immediately and stops on Ctrl-C; the command then waits for
/// transcription to finish so scripts can consume the transcript on exit.
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record headlessly until Ctrl-C, then transcribe and exit."
    )

    @Option(name: .long, help: "Recordings root directory (overrides the config file).")
    var out: String?

    @Flag(name: .long, help: "Skip the canonical post-recording transcription.")
    var noTranscribe = false

    @Option(
        name: .long,
        help: "Append stable, aligned transcript segments to this file while recording."
    )
    var liveTranscript: String?

    mutating func run() async throws {
        let root = Config.resolveRoot(cliOverride: out)
        let shouldTranscribe = !noTranscribe && Config.transcriptionEnabled()
        let liveTranscriptURL = liveTranscript.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        try await Self.runHeadless(
            root: root,
            shouldTranscribe: shouldTranscribe,
            liveTranscriptURL: liveTranscriptURL
        )
    }

    @MainActor
    private static func runHeadless(
        root: URL,
        shouldTranscribe: Bool,
        liveTranscriptURL: URL?
    ) async throws {
        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
            DoctorReport.print(checks)
            throw ExitCode(1)
        }

        let live: LiveTranscriptionSession?
        if let liveTranscriptURL {
            FileHandle.standardError.write(Data("preparing live transcription…\n".utf8))
            let newLive = LiveTranscriptionSession(output: liveTranscriptURL)
            try await newLive.prepare()
            live = newLive
            FileHandle.standardError.write(Data(
                "live transcript → \(liveTranscriptURL.path)\n".utf8
            ))
        } else {
            live = nil
        }

        let onMicBuffer: AudioBufferHandler?
        let onSystemBuffer: AudioBufferHandler?
        if let live {
            onMicBuffer = { buffer in live.receiveMic(buffer) }
            onSystemBuffer = { buffer in live.receiveSystem(buffer) }
        } else {
            onMicBuffer = nil
            onSystemBuffer = nil
        }
        let session = try RecordingSession(
            root: root,
            onMicBuffer: onMicBuffer,
            onSystemBuffer: onSystemBuffer
        )
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

        var liveFailure: Error?
        if let live {
            do {
                try await live.finish()
                FileHandle.standardError.write(Data("live transcript finalized\n".utf8))
            } catch {
                liveFailure = error
                FileHandle.standardError.write(Data(
                    "live transcription failed: \(error)\n".utf8
                ))
            }
        }

        let transcription = TranscriptionCoordinator()
        if shouldTranscribe {
            await transcription.setStatusHandler { status in
                let message: String?
                switch status {
                case .idle:
                    message = nil
                case .transcribing(let name, let queued):
                    message = queued > 0
                        ? "transcribing \(name) · \(queued) queued\n"
                        : "transcribing \(name)\n"
                case .failed(let name):
                    message = "transcription failed · \(name)\n"
                }
                if let message {
                    FileHandle.standardError.write(Data(message.utf8))
                }
            }
        } else {
            FileHandle.standardError.write(Data("transcription skipped\n".utf8))
        }

        try await transcription.enqueueAndWait(
            session.dir,
            transcriptionEnabled: shouldTranscribe,
            notificationsEnabled: false
        )
        if let liveFailure { throw liveFailure }
        print(session.dir.path)
    }

    /// Suspend without blocking the main actor until the user interrupts the
    /// recording. Restore SIGINT's default action afterward so a second
    /// Ctrl-C can abort a long model download or transcription.
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
        abstract: "Check microphone, system audio, and recordings folder."
    )

    func run() throws {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSession()
        NSApp.terminate(nil)
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
