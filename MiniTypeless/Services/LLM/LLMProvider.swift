import Foundation

struct LLMMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct LLMResult: Sendable {
    let text: String
    let inputTokens: Int?
    let outputTokens: Int?
}

protocol LLMProvider: Sendable {
    var displayName: String { get }
    var requiresNetwork: Bool { get }
    var isReady: Bool { get async }
    func prepare() async throws
    func process(messages: [LLMMessage]) async throws -> LLMResult
    func processStream(messages: [LLMMessage]) async throws -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    // Default non-streaming implementation
    func processStream(messages: [LLMMessage]) async throws -> AsyncThrowingStream<String, Error> {
        let result = try await process(messages: messages)
        return AsyncThrowingStream { continuation in
            continuation.yield(result.text)
            continuation.finish()
        }
    }
}
