import Foundation

/// Serial crash-recovery queue. Normal recordings are transcribed by their
/// live session; this actor only replays readable CAF files for sessions whose
/// authoritative transcript never reached a terminal state.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case recovering(session: String, queued: Int)
        case failed(session: String)
    }

    private struct Job {
        let dir: URL
    }

    private var queue: [Job] = []
    private var draining = false
    private var resources: LiveTranscriptionResources?
    private var resourceTask: Task<LiveTranscriptionResources, Error>?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Finish the normal live path. Hooks only run after transcript.json is
    /// finalized (or immediately for explicitly audio-only sessions).
    func completed(_ sessionDir: URL) {
        runHook(for: sessionDir)
    }

    func completedAudioOnly(_ sessionDir: URL) {
        runHook(for: sessionDir)
    }

    /// The active recorder and recovery queue share one in-flight load and one
    /// set of model objects. Actor reentrancy would otherwise permit duplicate
    /// downloads when recovery and a new recording start together.
    func prepareResources() async throws -> LiveTranscriptionResources {
        if let resources { return resources }
        if let resourceTask { return try await resourceTask.value }
        let task = Task { try await LiveTranscriptionResources.prepare() }
        resourceTask = task
        do {
            let loaded = try await task.value
            resources = loaded
            resourceTask = nil
            return loaded
        } catch {
            resourceTask = nil
            throw error
        }
    }

    /// Discover interrupted or incomplete live transcripts. Old transcript
    /// documents without the versioned live schema are treated as completed,
    /// so upgrading never retranscribes legacy sessions.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let queued = Set(queue.map(\.dir))
        let pending = entries
            .filter { SessionRecovery.needsRecovery($0) && !queued.contains($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for dir in pending {
            queue.append(Job(dir: dir))
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "recovering \(pending.count) incomplete transcript(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    func waitUntilIdle() async {
        guard draining || !queue.isEmpty else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            let name = job.dir.lastPathComponent
            publish(.recovering(session: name, queued: queue.count))
            do {
                try await recover(job.dir)
                log(job.dir, "recovery complete")
                runHook(for: job.dir)
            } catch {
                log(job.dir, "recovery failed: \(error)")
                lastFailure = name
            }
        }
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        if queue.isEmpty {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } else {
            drainIfIdle()
        }
    }

    private func recover(_ dir: URL) async throws {
        let meta = try SessionRecovery.readMeta(dir)
        let resources = try await prepareResources()
        let live = LiveTranscriptionSession(
            sessionDir: dir,
            startedAt: meta.startedAt,
            resources: resources,
            initialStatus: .recovering
        )
        try await live.prepare()
        await live.configureTrackOffsets(
            micMs: meta.offsets[.mic] ?? 0,
            systemMs: meta.offsets[.system] ?? 0
        )

        var replayFailure: Error?
        do {
            try await live.replay(
                mic: trackURL(meta.files[.mic], in: dir),
                system: trackURL(meta.files[.system], in: dir)
            )
        } catch {
            replayFailure = error
        }
        do {
            try await live.finish()
        } catch {
            throw replayFailure ?? error
        }
        if let replayFailure { throw replayFailure }
    }

    private func trackURL(_ name: String?, in dir: URL) -> URL? {
        guard let name else { return nil }
        return dir.appendingPathComponent(name)
    }

    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

enum SessionRecovery {
    struct Meta {
        let startedAt: Date
        let transcriptionEnabled: Bool
        let files: [TranscriptTrackID: String]
        let offsets: [TranscriptTrackID: Int]
    }

    enum RecoveryError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func needsRecovery(_ dir: URL) -> Bool {
        guard let meta = try? readMeta(dir), meta.transcriptionEnabled else { return false }
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return true }
        guard
            let data = try? Data(contentsOf: transcriptURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return true }

        // Legacy JSON had neither a schema version nor lifecycle and was
        // written only after batch transcription completed.
        if json["schema_version"] == nil, json["status"] == nil { return false }
        guard let status = json["status"] as? String else { return true }
        return status != TranscriptLifecycle.complete.rawValue
            && status != TranscriptLifecycle.failed.rawValue
    }

    static func readMeta(_ dir: URL) throws -> Meta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawFiles = json["files"] as? [String: String]
        else { throw RecoveryError.unreadable(url) }

        let iso = ISO8601DateFormatter()
        let startedAt = (json["started"] as? String).flatMap(iso.date(from:)) ?? Date()
        let rawOffsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var files: [TranscriptTrackID: String] = [:]
        var offsets: [TranscriptTrackID: Int] = [:]
        for track in TranscriptTrackID.allCases {
            files[track] = rawFiles[track.rawValue]
            offsets[track] = rawOffsets[track.rawValue] ?? 0
        }
        return Meta(
            startedAt: startedAt,
            transcriptionEnabled: json["transcription_enabled"] as? Bool ?? true,
            files: files,
            offsets: offsets
        )
    }
}
