import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "ClaudeCodeLLM")

final class ClaudeCodeLLM: LLMProvider, @unchecked Sendable {
    let displayName = "Claude Code CLI"
    let requiresNetwork = true

    private let cliPath: String
    private let model: String

    init(cliPath: String, model: String = Defaults.claudeCodeModel) {
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
            throw CLILLMError.cliNotFound(name: "Claude Code", path: "")
        }
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw CLILLMError.cliNotFound(name: "Claude Code", path: cliPath)
        }
    }

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        try await prepare()

        let systemPrompt = messages.first { $0.role == .system }?.content ?? ""
        let userText = messages.filter { $0.role == .user }.map(\.content).joined(separator: "\n")

        guard !userText.isEmpty else {
            throw CLILLMError.emptyInput
        }

        let cliPath = self.cliPath
        let model = self.model

        // Build combined prompt (system + user)
        let fullPrompt: String
        if systemPrompt.isEmpty {
            fullPrompt = userText
        } else {
            fullPrompt = systemPrompt + "\n\n" + userText
        }

        let args = ["-p", "--output-format", "text", "--model", model, fullPrompt]

        // Clear env vars that trigger nesting detection
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDE_CODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

        return try await Task.detached {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cliPath)
            proc.arguments = args
            proc.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr

            do {
                try proc.run()
            } catch {
                logger.error("Failed to launch Claude CLI: \(error.localizedDescription)")
                throw CLILLMError.launchFailed(error.localizedDescription)
            }

            logger.info("Launched Claude CLI: \(cliPath) with model \(model)")

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()

            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if proc.terminationStatus != 0 {
                logger.error("Claude CLI exited with \(proc.terminationStatus): \(errorOutput)")
                throw CLILLMError.cliError(exitCode: Int(proc.terminationStatus), message: errorOutput)
            }

            guard !output.isEmpty else {
                logger.error("Claude CLI returned empty output")
                throw CLILLMError.invalidOutput
            }

            logger.info("Claude CLI output (\(output.count) chars): \(output.prefix(200))...")
            return LLMResult(text: output, inputTokens: nil, outputTokens: nil)
        }.value
    }
}

// MARK: - Shared CLI LLM Errors

enum CLILLMError: LocalizedError {
    case cliNotFound(name: String, path: String)
    case emptyInput
    case cliError(exitCode: Int, message: String)
    case invalidOutput
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let name, let path):
            if path.isEmpty {
                return "\(name) CLI path not configured. Set it in Settings \u{2192} LLM."
            }
            return "\(name) CLI not found at: \(path)"
        case .emptyInput:
            return "No text to process"
        case .cliError(let exitCode, let message):
            let truncated = message.prefix(200)
            return "CLI error (exit \(exitCode)): \(truncated)"
        case .invalidOutput:
            return "CLI returned empty output"
        case .launchFailed(let reason):
            return "Failed to launch CLI: \(reason)"
        }
    }
}
