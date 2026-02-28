import Foundation
import WhisperKit
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "WhisperKitSTT")

final class WhisperKitSTT: STTProvider, @unchecked Sendable {
    let displayName = "WhisperKit (Local)"
    let requiresNetwork = false

    // Cache the loaded WhisperKit instance across provider recreations.
    // Loading a model (~1.6GB) takes seconds; decoding options are cheap to vary.
    nonisolated(unsafe) private static var cachedKit: WhisperKit?
    nonisolated(unsafe) private static var cachedModelName: String?

    private var whisperKit: WhisperKit?
    private let modelName: String
    private let language: String
    private let temperature: Float
    private let temperatureFallbackCount: Int
    private let usePrefillPrompt: Bool
    private let compressionRatioThreshold: Float
    private let noSpeechThreshold: Float

    init(
        modelName: String = Defaults.whisperModel,
        language: String = "zh",
        temperature: Float = Defaults.whisperTemperature,
        temperatureFallbackCount: Int = Defaults.whisperTempFallbackCount,
        usePrefillPrompt: Bool = Defaults.whisperUsePrefillPrompt,
        compressionRatioThreshold: Float = Defaults.whisperCompressionRatioThreshold,
        noSpeechThreshold: Float = Defaults.whisperNoSpeechThreshold
    ) {
        self.modelName = modelName
        self.language = language
        self.temperature = temperature
        self.temperatureFallbackCount = temperatureFallbackCount
        self.usePrefillPrompt = usePrefillPrompt
        self.compressionRatioThreshold = compressionRatioThreshold
        self.noSpeechThreshold = noSpeechThreshold
    }

    var isReady: Bool {
        get async { whisperKit != nil || (Self.cachedKit != nil && Self.cachedModelName == modelName) }
    }

    func prepare() async throws {
        // Reuse cached model if same variant
        if let cached = Self.cachedKit, Self.cachedModelName == modelName {
            self.whisperKit = cached
            logger.info("Reusing cached WhisperKit model: \(self.modelName)")
            return
        }

        // Check model is actually downloaded (prevent implicit download)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(modelName)")
        guard FileManager.default.fileExists(atPath: modelDir.path()) else {
            throw WhisperKitSTTError.modelNotDownloaded(modelName)
        }

        logger.info("Loading WhisperKit model: \(self.modelName)")
        let kit = try await WhisperKit(model: modelName)
        self.whisperKit = kit
        Self.cachedKit = kit
        Self.cachedModelName = modelName
        logger.info("WhisperKit model loaded and cached")
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        guard let kit = whisperKit else {
            try await prepare()
            return try await transcribe(audioSamples: audioSamples)
        }

        logger.info("Transcribing \(audioSamples.count) samples")
        let options = DecodingOptions(
            language: language,
            temperature: temperature,
            temperatureFallbackCount: temperatureFallbackCount,
            usePrefillPrompt: usePrefillPrompt,
            compressionRatioThreshold: compressionRatioThreshold,
            noSpeechThreshold: noSpeechThreshold
        )
        let results = try await kit.transcribe(audioArray: audioSamples, decodeOptions: options)

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        logger.info("Transcription: \(text)")

        return TranscriptionResult(
            text: text,
            language: language,
            duration: nil
        )
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        guard let kit = whisperKit else {
            try await prepare()
            return try await transcribe(fileURL: fileURL)
        }

        let options = DecodingOptions(
            language: language,
            temperature: temperature,
            temperatureFallbackCount: temperatureFallbackCount,
            usePrefillPrompt: usePrefillPrompt,
            compressionRatioThreshold: compressionRatioThreshold,
            noSpeechThreshold: noSpeechThreshold
        )
        let results = try await kit.transcribe(audioPath: fileURL.path(), decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        return TranscriptionResult(
            text: text,
            language: language,
            duration: nil
        )
    }
}

enum WhisperKitSTTError: LocalizedError {
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded(let model):
            "WhisperKit model '\(model)' is not downloaded. Please download it in Settings → Models."
        }
    }
}
