import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "LocalMLXLLM")

/// Local LLM using MLX Swift. Requires mlx-swift-lm package.
/// Currently a stub – will be fully implemented when mlx-swift-lm is integrated.
final class LocalMLXLLM: LLMProvider, @unchecked Sendable {
    let displayName = "Local MLX"
    let requiresNetwork = false

    private let modelName: String

    init(modelName: String = Defaults.localLLMModel) {
        self.modelName = modelName
    }

    var isReady: Bool {
        get async {
            // TODO: Check if model is downloaded
            false
        }
    }

    func prepare() async throws {
        logger.info("MLX LLM prepare: \(self.modelName)")
        // TODO: Load model with MLXLLM
        throw LocalMLXError.notImplemented
    }

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        // TODO: Implement with MLXLLM.generate
        throw LocalMLXError.notImplemented
    }
}

enum LocalMLXError: LocalizedError {
    case notImplemented
    case modelNotFound

    var errorDescription: String? {
        switch self {
        case .notImplemented: "Local MLX LLM is not yet implemented. Use a cloud provider."
        case .modelNotFound: "Local model not found. Please download it first."
        }
    }
}
