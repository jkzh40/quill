import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
        ]
    }

    static func checkMicrophone() -> Check {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for quill (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Report the complete live stack. Recording still performs an actual
    /// load before capture, which is the authoritative readiness check.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let fileManager = FileManager.default
        let modelsRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("FluidAudio/Models")
        let asrReady = AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v2),
            version: .v2
        )
        let vadReady = ModelNames.VAD.requiredModels.allSatisfy {
            fileManager.fileExists(
                atPath: modelsRoot
                    .appendingPathComponent(Repo.vad.folderName)
                    .appendingPathComponent($0).path
            )
        }
        let variant = LSEENDVariant.dihard3
        let step = LSEENDStepSize.step100ms
        let relativeModel = variant.fileName(forStep: step)
        let relativePath = variant.repo.subPath.map { "\($0)/\(relativeModel)" }
            ?? relativeModel
        let diarizerReady = fileManager.fileExists(
            atPath: modelsRoot
                .appendingPathComponent(variant.repo.folderName)
                .appendingPathComponent(relativePath).path
        )
        if asrReady && vadReady && diarizerReady {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        var missing: [String] = []
        if !asrReady { missing.append("Parakeet") }
        if !vadReady { missing.append("Silero VAD") }
        if !diarizerReady { missing.append("LS-EEND") }
        return Check(
            name: "transcription",
            status: .warn("models not cached: \(missing.joined(separator: ", "))"),
            remediation: "downloads and validates them before recording starts — run a short test while online"
        )
    }

    static func print(_ checks: [Check]) {
        write(checks, to: nil)
    }

    static func printToStandardError(_ checks: [Check]) {
        write(checks, to: .standardError)
    }

    private static func write(_ checks: [Check], to handle: FileHandle?) {
        var lines: [String] = []
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            lines.append("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                lines.append("    → \(r)")
            }
        }
        let output = lines.joined(separator: "\n") + "\n"
        if let handle {
            handle.write(Data(output.utf8))
        } else {
            Swift.print(output, terminator: "")
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
