import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "CodexLLM")

final class CodexLLM: LLMProvider, @unchecked Sendable {
    let displayName = "Codex CLI"
    let requiresNetwork = true

    private let cliPath: String
    private let model: String

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

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        try await prepare()

        let systemPrompt = messages.first { $0.role == .system }?.content ?? ""
        let userText = messages.filter { $0.role == .user }.map(\.content).joined(separator: "\n")

        guard !userText.isEmpty else {
            throw CLILLMError.emptyInput
        }

        let cliPath = self.cliPath
        let model = self.model

        let fullPrompt: String
        if systemPrompt.isEmpty {
            fullPrompt = userText
        } else {
            fullPrompt = systemPrompt + "\n\n" + userText
        }

        // Use a temp file for output since codex exec outputs agent activity to stdout
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
                // Extract just the ERROR line from verbose codex output
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
