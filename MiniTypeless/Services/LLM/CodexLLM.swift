import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "CodexLLM")

final class CodexLLM: LLMProvider, @unchecked Sendable {
    let displayName = "Codex CLI"
    let requiresNetwork = true

    private let cliPath: String
    private let model: String

    // Warm process state (pre-launched during transcription)
    private var warmProcess: Process?
    private var warmStdinHandle: FileHandle?
    private var warmStdout: Pipe?
    private var warmStderr: Pipe?
    private var warmOutputFile: URL?
    private var warmSystemPrompt: String?

    init(cliPath: String, model: String = Defaults.codexModel) {
        self.cliPath = cliPath
        self.model = model
    }

    var isReady: Bool {
        get async {
            !cliPath.isEmpty && FileManager.default.isExecutableFile(atPath: cliPath)
        }
    }

    func prepare() async throws {
        guard !cliPath.isEmpty else {
            throw CLILLMError.cliNotFound(name: "Codex", path: "")
        }
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw CLILLMError.cliNotFound(name: "Codex", path: cliPath)
        }
    }

    // MARK: - Pre-launch (warm up)

    /// Pre-launch the CLI process with `-` stdin marker, leaving stdin open for the prompt.
    /// Call this during transcription to overlap CLI startup with STT work.
    func warmUp(systemPrompt: String) {
        guard !cliPath.isEmpty, FileManager.default.isExecutableFile(atPath: cliPath) else {
            logger.warning("warmUp: CLI not found at '\(self.cliPath)', skipping")
            return
        }

        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-typeless-codex-\(UUID().uuidString).txt")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cliPath)
        // `-` at end tells codex to read prompt from stdin
        proc.arguments = [
            "exec",
            "-m", model,
            "--skip-git-repo-check",
            "--full-auto",
            "--ephemeral",
            "-o", outputFile.path,
            "-",
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
            warmProcess = proc
            warmStdinHandle = stdinPipe.fileHandleForWriting
            warmStdout = stdoutPipe
            warmStderr = stderrPipe
            warmOutputFile = outputFile
            warmSystemPrompt = systemPrompt
            logger.info("warmUp: pre-launched Codex CLI (pid=\(proc.processIdentifier))")
        } catch {
            logger.warning("warmUp: failed to launch: \(error.localizedDescription)")
        }
    }

    /// Terminate any pre-launched process.
    func cancelWarm() {
        guard let proc = warmProcess else { return }
        if proc.isRunning {
            proc.terminate()
            logger.info("cancelWarm: terminated pre-launched Codex CLI")
        }
        if let outputFile = warmOutputFile {
            try? FileManager.default.removeItem(at: outputFile)
        }
        clearWarmState()
    }

    private func clearWarmState() {
        warmProcess = nil
        warmStdinHandle = nil
        warmStdout = nil
        warmStderr = nil
        warmOutputFile = nil
        warmSystemPrompt = nil
    }

    // MARK: - Process

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        try await prepare()

        let systemPrompt = messages.first { $0.role == .system }?.content ?? ""
        let userText = messages.filter { $0.role == .user }.map(\.content).joined(separator: "\n")

        guard !userText.isEmpty else {
            throw CLILLMError.emptyInput
        }

        // Check for warm (pre-launched) process
        if let proc = warmProcess, proc.isRunning,
           let stdinHandle = warmStdinHandle,
           let stdout = warmStdout,
           let stderr = warmStderr,
           let outputFile = warmOutputFile {
            // Use the stored system prompt from warmUp, or the one from messages
            let sysPrompt = warmSystemPrompt ?? systemPrompt
            logger.info("process: using pre-launched warm process")
            let warmProc = proc
            let warmOutFile = outputFile
            clearWarmState()

            let fullPrompt: String
            if sysPrompt.isEmpty {
                fullPrompt = userText
            } else {
                fullPrompt = sysPrompt + "\n\n" + userText
            }

            return try await Task.detached {
                // Write full prompt to stdin and close it
                stdinHandle.write(fullPrompt.data(using: .utf8)!)
                try stdinHandle.close()

                // Read pipes to prevent buffer deadlock
                let _ = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                warmProc.waitUntilExit()

                let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if warmProc.terminationStatus != 0 {
                    logger.error("Codex CLI (warm) exited with \(warmProc.terminationStatus): \(errorOutput)")
                    try? FileManager.default.removeItem(at: warmOutFile)
                    let errorMessage = CodexLLM.extractErrorMessage(from: errorOutput)
                    throw CLILLMError.cliError(exitCode: Int(warmProc.terminationStatus), message: errorMessage)
                }

                // Read the output file written by -o flag
                let output: String
                do {
                    output = try String(contentsOf: warmOutFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try? FileManager.default.removeItem(at: warmOutFile)
                } catch {
                    try? FileManager.default.removeItem(at: warmOutFile)
                    logger.error("Failed to read Codex output file: \(error.localizedDescription)")
                    throw CLILLMError.invalidOutput
                }

                guard !output.isEmpty else {
                    logger.error("Codex CLI (warm) returned empty output")
                    throw CLILLMError.invalidOutput
                }

                logger.info("Codex CLI (warm) output (\(output.count) chars): \(output.prefix(200))...")
                return LLMResult(text: output, inputTokens: nil, outputTokens: nil)
            }.value
        }

        // Cold path: launch a fresh process with prompt as argument
        logger.info("process: cold launch (no warm process)")
        let cliPath = self.cliPath
        let model = self.model

        let fullPrompt: String
        if systemPrompt.isEmpty {
            fullPrompt = userText
        } else {
            fullPrompt = systemPrompt + "\n\n" + userText
        }

        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-typeless-codex-\(UUID().uuidString).txt")

        let args = [
            "exec",
            "-m", model,
            "--skip-git-repo-check",
            "--full-auto",
            "--ephemeral",
            "-o", outputFile.path,
            fullPrompt,
        ]

        return try await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = args

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            do {
                try proc.run()
            } catch {
                logger.error("Failed to launch Codex CLI: \(error.localizedDescription)")
                throw CLILLMError.launchFailed(error.localizedDescription)
            }

            logger.info("Launched Codex CLI: \(cliPath) exec -m \(model)")

            // Read pipes to prevent buffer deadlock
            let _ = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus != 0 {
                logger.error("Codex CLI exited with \(proc.terminationStatus): \(errorOutput)")
                try? FileManager.default.removeItem(at: outputFile)
                let errorMessage = CodexLLM.extractErrorMessage(from: errorOutput)
                throw CLILLMError.cliError(exitCode: Int(proc.terminationStatus), message: errorMessage)
            }

            // Read the output file written by -o flag
            let output: String
            do {
                output = try String(contentsOf: outputFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: outputFile)
            } catch {
                try? FileManager.default.removeItem(at: outputFile)
                logger.error("Failed to read Codex output file: \(error.localizedDescription)")
                throw CLILLMError.invalidOutput
            }

            guard !output.isEmpty else {
                logger.error("Codex CLI returned empty output")
                throw CLILLMError.invalidOutput
            }

            logger.info("Codex CLI output (\(output.count) chars): \(output.prefix(200))...")
            return LLMResult(text: output, inputTokens: nil, outputTokens: nil)
        }.value
    }

    /// Extract the meaningful error message from codex's verbose stderr output.
    private static func extractErrorMessage(from output: String) -> String {
        let lines = output.components(separatedBy: .newlines)
        // Look for "ERROR:" lines first
        if let errorLine = lines.first(where: { $0.hasPrefix("ERROR:") }) {
            // Try to parse JSON detail
            let jsonPart = errorLine.replacingOccurrences(of: "ERROR: ", with: "")
            if let data = jsonPart.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                return detail
            }
            return jsonPart
        }
        // Fallback: return last non-empty line
        if let lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return lastLine
        }
        return output
    }
}
