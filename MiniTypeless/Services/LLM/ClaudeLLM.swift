import Foundation
import SwiftAnthropic
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "ClaudeLLM")

final class ClaudeLLM: LLMProvider, @unchecked Sendable {
    let displayName = "Claude"
    let requiresNetwork = true

    private let apiKey: String
    private let baseURL: String?
    private let model: String
    private let temperature: Float
    private let maxTokens: Int

    init(apiKey: String, baseURL: String? = nil, model: String = Defaults.claudeModel, temperature: Float = Defaults.llmTemperature, maxTokens: Int = Defaults.llmMaxTokens) {
        self.apiKey = apiKey
        self.baseURL = baseURL?.isEmpty == true ? nil : baseURL
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    var isReady: Bool {
        get async { !apiKey.isEmpty }
    }

    func prepare() async throws {
        guard !apiKey.isEmpty else {
            throw ClaudeLLMError.missingAPIKey
        }
    }

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        let service: AnthropicService
        if let baseURL {
            service = AnthropicServiceFactory.service(
                apiKey: apiKey,
                basePath: baseURL,
                betaHeaders: nil
            )
        } else {
            service = AnthropicServiceFactory.service(
                apiKey: apiKey,
                betaHeaders: nil
            )
        }

        let systemMessage = messages.first { $0.role == .system }?.content
        let userMessages = messages.filter { $0.role != .system }

        let anthropicMessages = userMessages.map { msg in
            MessageParameter.Message(
                role: msg.role == .user ? .user : .assistant,
                content: .text(msg.content)
            )
        }

        let parameters = MessageParameter(
            model: .other(model),
            messages: anthropicMessages,
            maxTokens: maxTokens,
            system: systemMessage.map { .text($0) },
            temperature: Double(temperature)
        )

        let response = try await service.createMessage(parameters)

        let text = response.content.compactMap { block -> String? in
            if case .text(let t, _) = block {
                return t
            }
            return nil
        }.joined()

        logger.info("Claude response: \(text.prefix(100))...")

        return LLMResult(
            text: text,
            inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens
        )
    }
}

enum ClaudeLLMError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Anthropic API key is not configured"
        }
    }
}
