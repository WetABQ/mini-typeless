import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "SenseVoiceSTT")

final class SenseVoiceSTT: STTProvider, @unchecked Sendable {
    let displayName = "SenseVoice (Local)"
    let requiresNetwork = false

    // Cache the loaded recognizer across provider recreations.
    nonisolated(unsafe) private static var cachedRecognizer: SherpaOnnxOfflineRecognizer?
    nonisolated(unsafe) private static var cachedModelName: String?

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private let modelName: String
    private let language: String

    init(modelName: String = Defaults.senseVoiceModel, language: String = "auto") {
        self.modelName = modelName
        self.language = language
    }

    var isReady: Bool {
        get async {
            recognizer != nil || (Self.cachedRecognizer != nil && Self.cachedModelName == modelName)
        }
    }

    func prepare() async throws {
        // Reuse cached recognizer if same model
        if let cached = Self.cachedRecognizer, Self.cachedModelName == modelName {
            self.recognizer = cached
            logger.info("Reusing cached SenseVoice recognizer: \(self.modelName)")
            return
        }

        // Check model files exist
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let modelDir = documents.appendingPathComponent("sherpa-onnx-models/\(modelName)")
        let modelPath = modelDir.appendingPathComponent("model.int8.onnx")
        let tokensPath = modelDir.appendingPathComponent("tokens.txt")

        guard FileManager.default.fileExists(atPath: modelPath.path()) else {
            throw SenseVoiceModelError.modelNotDownloaded(modelName)
        }
        guard FileManager.default.fileExists(atPath: tokensPath.path()) else {
            throw SenseVoiceModelError.missingRequiredFile("tokens.txt")
        }

        logger.info("Loading SenseVoice model: \(self.modelName)")

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath.path(),
            language: language,
            useInverseTextNormalization: true
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath.path(),
            numThreads: 2,
            debug: 0,
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)

        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        let rec = SherpaOnnxOfflineRecognizer(config: &config)
        self.recognizer = rec
        Self.cachedRecognizer = rec
        Self.cachedModelName = modelName
        logger.info("SenseVoice model loaded and cached")
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        guard let rec = recognizer else {
            try await prepare()
            return try await transcribe(audioSamples: audioSamples)
        }

        logger.info("Transcribing \(audioSamples.count) samples with SenseVoice")
        let result = rec.decode(samples: audioSamples, sampleRate: 16_000)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = result.lang.isEmpty ? language : result.lang
        logger.info("SenseVoice transcription: \(text.prefix(200))")

        return TranscriptionResult(
            text: text,
            language: lang,
            duration: nil
        )
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        // Read audio file and convert to 16kHz Float32 samples
        let audioFile = try AVAudioFile(forReading: fileURL)
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
            throw SenseVoiceSTTError.invalidAudioFormat
        }
        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw SenseVoiceSTTError.invalidAudioFormat
        }

        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return try await transcribe(audioSamples: samples)
    }
}

import AVFoundation

private enum SenseVoiceSTTError: LocalizedError {
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .invalidAudioFormat:
            "Invalid audio format for SenseVoice transcription"
        }
    }
}
