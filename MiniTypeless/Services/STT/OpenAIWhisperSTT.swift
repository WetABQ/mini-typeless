import Foundation
import SwiftOpenAI
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "OpenAIWhisperSTT")

final class OpenAIWhisperSTT: STTProvider, @unchecked Sendable {
    let displayName = "OpenAI Whisper (Cloud)"
    let requiresNetwork = true

    private let apiKey: String
    private let baseURL: String?
    private let language: String

    init(apiKey: String, baseURL: String? = nil, language: String = "zh") {
        self.apiKey = apiKey
        self.baseURL = baseURL?.isEmpty == true ? nil : baseURL
        self.language = language
    }

    var isReady: Bool {
        get async { !apiKey.isEmpty }
    }

    func prepare() async throws {
        guard !apiKey.isEmpty else {
            throw OpenAIWhisperError.missingAPIKey
        }
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        let wavData = AudioConverter.wavData(from: audioSamples)
        return try await transcribeData(wavData, filename: "recording.wav")
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        let data = try Data(contentsOf: fileURL)
        return try await transcribeData(data, filename: fileURL.lastPathComponent)
    }

    private func transcribeData(_ data: Data, filename: String) async throws -> TranscriptionResult {
        let service: OpenAIService
        if let baseURL {
            service = OpenAIServiceFactory.service(
                apiKey: apiKey,
                overrideBaseURL: baseURL
            )
        } else {
            service = OpenAIServiceFactory.service(apiKey: apiKey)
        }

        let parameters = AudioTranscriptionParameters(
            fileName: filename,
            file: data,
            model: .whisperOne,
            language: language
        )

        let result = try await service.createTranscription(parameters: parameters)
        logger.info("OpenAI Whisper result: \(result.text)")

        return TranscriptionResult(
            text: result.text,
            language: language,
            duration: result.duration.flatMap { Double($0) }
        )
    }
}

enum OpenAIWhisperError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "OpenAI API key is not configured"
        }
    }
}
