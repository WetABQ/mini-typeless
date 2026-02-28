import Foundation
import Speech
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "AppleSpeechSTT")

final class AppleSpeechSTT: STTProvider, @unchecked Sendable {
    let displayName = "Apple Speech"
    let requiresNetwork = false

    private let locale: Locale
    private var recognizer: SFSpeechRecognizer?

    init(language: String = "zh-Hans") {
        self.locale = Locale(identifier: language)
    }

    var isReady: Bool {
        get async {
            SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    func prepare() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else {
                throw AppleSpeechError.notAuthorized
            }
        } else if status != .authorized {
            throw AppleSpeechError.notAuthorized
        }
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult {
        let fileURL = try AudioConverter.writeTemporaryWAV(samples: audioSamples)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try await transcribe(fileURL: fileURL)
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionResult {
        let rec = recognizer ?? SFSpeechRecognizer(locale: locale)
        guard let recognizer = rec, recognizer.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        let transcriptionResult: TranscriptionResult = try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { [locale] result, error in
                guard !hasResumed else { return }
                if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    hasResumed = true
                    let text = result.bestTranscription.formattedString
                    let duration = result.bestTranscription.segments.last.map { $0.timestamp + $0.duration }
                    let tr = TranscriptionResult(text: text, language: locale.identifier, duration: duration)
                    continuation.resume(returning: tr)
                }
            }
        }

        logger.info("Apple Speech result: \(transcriptionResult.text)")
        return transcriptionResult
    }
}

enum AppleSpeechError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Speech recognition not authorized"
        case .recognizerUnavailable: "Speech recognizer unavailable for selected language"
        }
    }
}
