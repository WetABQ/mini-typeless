import Foundation
import SwiftOpenAI
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "OpenAILLM")

final class OpenAILLM: LLMProvider, @unchecked Sendable {
    let displayName = "OpenAI"
    let requiresNetwork = true

    private let apiKey: String
    private let baseURL: String?
    private let model: String
    private let temperature: Float
    private let maxTokens: Int

    init(apiKey: String, baseURL: String? = nil, model: String = Defaults.openAILLMModel, temperature: Float = Defaults.llmTemperature, maxTokens: Int = Defaults.llmMaxTokens) {
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
            throw OpenAILLMError.missingAPIKey
        }
    }

    func process(messages: [LLMMessage]) async throws -> LLMResult {
        let service: OpenAIService
        if let baseURL {
            service = OpenAIServiceFactory.service(apiKey: apiKey, overrideBaseURL: baseURL)
        } else {
            service = OpenAIServiceFactory.service(apiKey: apiKey)
        }

        let chatMessages: [ChatCompletionParameters.Message] = messages.map { msg in
            switch msg.role {
            case .system: .init(role: .system, content: .text(msg.content))
            case .user: .init(role: .user, content: .text(msg.content))
            case .assistant: .init(role: .assistant, content: .text(msg.content))
            }
        }

        let parameters = ChatCompletionParameters(
            messages: chatMessages,
            model: .custom(model),
            maxTokens: maxTokens,
            temperature: Double(temperature)
        )

        let response = try await service.startChat(parameters: parameters)
        let text = response.choices?.first?.message?.content ?? ""

        logger.info("OpenAI response: \(text.prefix(100))...")

        return LLMResult(
            text: text,
            inputTokens: response.usage?.promptTokens,
            outputTokens: response.usage?.completionTokens
        )
    }
}

enum OpenAILLMError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "OpenAI API key is not configured"
        }
    }
}
