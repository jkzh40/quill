import Darwin
import FluidAudio
import Foundation

/// Loads the shared Parakeet v2 model while filtering one verified Core ML
/// diagnostic emitted by the compiled preprocessor at load time.
enum ParakeetModelLoader {
    /// Loading FluidAudio's v2 `Preprocessor.mlmodelc` prints this exact line
    /// for every MLComputeUnits setting, although MLModel initializes and Quill
    /// transcribes successfully. Core ML is rejecting one zero-sized speculative
    /// `slice_by_index` specialization and falling back to its working path.
    /// A real fix requires reconverting that upstream model with a nonzero
    /// lower-bound shape; Quill can only remove the misleading terminal noise.
    private static let knownCoreMLDiagnostic =
        "E5RT encountered an STL exception. msg = Failed to PropagateInputTensorShapes: "
        + "std::runtime_error during type inference for ios17.slice_by_index: zero shape error."

    static func loadV2() async throws -> AsrModels {
        if ProcessInfo.processInfo.environment["QUILL_SHOW_COREML_WARNINGS"] == "1" {
            return try await AsrModels.downloadAndLoad(version: .v2)
        }
        return try await filteringKnownDiagnostic {
            try await AsrModels.downloadAndLoad(version: .v2)
        }
    }

    /// Model loading happens before capture and before Quill starts any other
    /// worker that writes stdout. Temporarily capture fd 1, remove only the
    /// byte-exact known warning, then replay every other diagnostic unchanged.
    private static func filteringKnownDiagnostic<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-coreml-stdout-\(UUID().uuidString)")
        let captureFD = Darwin.open(captureURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard captureFD >= 0 else { return try await operation() }
        defer {
            Darwin.close(captureFD)
            try? FileManager.default.removeItem(at: captureURL)
        }

        let savedStdout = Darwin.dup(STDOUT_FILENO)
        guard savedStdout >= 0 else { return try await operation() }
        defer { Darwin.close(savedStdout) }

        fflush(stdout)
        guard Darwin.dup2(captureFD, STDOUT_FILENO) >= 0 else {
            return try await operation()
        }

        let result: Result<T, Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }

        fflush(stdout)
        _ = Darwin.dup2(savedStdout, STDOUT_FILENO)

        _ = Darwin.lseek(captureFD, 0, SEEK_SET)
        let captured = FileHandle(fileDescriptor: captureFD, closeOnDealloc: false)
            .readDataToEndOfFile()
        if let text = String(data: captured, encoding: .utf8) {
            let filtered = text.replacingOccurrences(of: knownCoreMLDiagnostic, with: "")
            if !filtered.isEmpty {
                FileHandle.standardOutput.write(Data(filtered.utf8))
            }
        } else if !captured.isEmpty {
            FileHandle.standardOutput.write(captured)
        }

        return try result.get()
    }
}
