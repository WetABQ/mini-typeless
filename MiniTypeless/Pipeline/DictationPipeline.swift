import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "DictationPipeline")

/// Orchestrates the full dictation flow: record → transcribe → LLM polish → inject.
@MainActor
final class DictationPipeline {
    private let appState: AppState
    private let recorder = AudioRecorder()
    private var pipelineTask: Task<Void, Never>?
    private var preLaunchedLLM: (any LLMProvider)?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Pre-warm the audio subsystem to avoid first-recording latency.
    func warmUpAudio() {
        Task.detached {
            self.recorder.warmUp()
        }
    }

    // MARK: - Public API

    func startDictation() async {
        guard appState.dictationState == .idle else {
            logger.warning("Cannot start dictation: state is \(self.appState.dictationState.statusText)")
            return
        }

        do {
            appState.dictationState = .recording
            appState.recordingStartTime = Date()

            // Wire audio level metering
            let state = appState
            recorder.audioLevelCallback = { level in
                Task { @MainActor in
                    state.audioLevel = level
                    state.audioLevelHistory.append(level)
                    if state.audioLevelHistory.count > 12 {
                        state.audioLevelHistory.removeFirst()
                    }
                }
            }

            try recorder.startRecording()
            logger.info("Dictation started")
        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
            appState.dictationState = .error(error.localizedDescription)
            resetAfterDelay()
        }
    }

    func stopDictation() async {
        guard appState.dictationState == .recording else {
            logger.warning("Cannot stop dictation: state is \(self.appState.dictationState.statusText)")
            return
        }

        recorder.audioLevelCallback = nil
        let samples = recorder.stopRecording()
        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)
        logger.info("stopDictation: got \(samples.count) samples from recorder")

        guard samples.count > 1600 else { // < 0.1s of audio at 16kHz
            logger.warning("Recording too short: \(samples.count) samples (need > 1600)")
            appState.dictationState = .error("Recording too short (\(samples.count) samples)")
            resetAfterDelay()
            return
        }

        // Run the pipeline in a cancellable task
        pipelineTask = Task {
            await runPipeline(samples: samples)
        }
    }

    /// Cancel a running transcription/processing pipeline.
    func cancelPipeline() {
        pipelineTask?.cancel()
        pipelineTask = nil

        // Terminate any pre-launched CLI process
        cancelPreLaunchedLLM()

        // Stop recording if still recording
        if recorder.recording {
            recorder.audioLevelCallback = nil
            _ = recorder.stopRecording()
        }

        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)
        logger.info("Pipeline cancelled by user")
        appState.dictationState = .idle
    }

    private func cancelPreLaunchedLLM() {
        if let claude = preLaunchedLLM as? ClaudeCodeLLM {
            claude.cancelWarm()
        } else if let codex = preLaunchedLLM as? CodexLLM {
            codex.cancelWarm()
        }
        preLaunchedLLM = nil
    }

    // MARK: - Pipeline execution

    private func runPipeline(samples: [Float]) async {
        let provider = appState.sttProviderType
        logger.info("runPipeline: starting with \(samples.count) samples, provider=\(provider.rawValue)")

        do {
            try Task.checkCancellation()

            let stt = createSTTProvider()

            // Only show "Loading model" for local model providers (WhisperKit).
            // API providers (OpenAI) and Apple Speech don't load a model.
            if provider == .whisperKit {
                appState.dictationState = .loadingModel
                logger.info("runPipeline: checking WhisperKit isReady...")
                if !(await stt.isReady) {
                    logger.info("runPipeline: WhisperKit not ready, calling prepare()...")
                    try await stt.prepare()
                    appState.cachedWhisperModel = appState.whisperModel
                    logger.info("runPipeline: WhisperKit prepare() completed")
                } else {
                    logger.info("runPipeline: WhisperKit already ready (cached)")
                }
            } else {
                // For API/Apple Speech, prepare if needed (permission request, etc.)
                if !(await stt.isReady) {
                    logger.info("runPipeline: STT not ready, calling prepare()...")
                    try await stt.prepare()
                }
            }

            try Task.checkCancellation()

            // Pre-launch CLI LLM process during transcription to overlap startup
            if appState.llmEnabled {
                let llm = createLLMProvider()
                let systemPrompt = appState.llmSystemPrompt
                if let claude = llm as? ClaudeCodeLLM {
                    claude.warmUp(systemPrompt: systemPrompt)
                    logger.info("runPipeline: pre-launched Claude CLI during transcription")
                } else if let codex = llm as? CodexLLM {
                    codex.warmUp(systemPrompt: systemPrompt)
                    logger.info("runPipeline: pre-launched Codex CLI during transcription")
                }
                preLaunchedLLM = llm
            }

            appState.dictationState = .transcribing
            logger.info("runPipeline: starting transcription...")
            let result = try await stt.transcribe(audioSamples: samples)
            let rawText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("runPipeline: transcription result = '\(rawText.prefix(200))'")

            guard !rawText.isEmpty else {
                logger.info("Empty transcription result")
                cancelPreLaunchedLLM()
                appState.dictationState = .error("No speech detected")
                resetAfterDelay()
                return
            }

            try Task.checkCancellation()

            appState.lastTranscription = rawText
            logger.info("Transcription: \(rawText)")

            // LLM polish (optional) — uses pre-launched provider if available
            var finalText = rawText
            if appState.llmEnabled {
                appState.dictationState = .processing
                try Task.checkCancellation()
                finalText = try await polishWithLLM(rawText, provider: preLaunchedLLM)
                preLaunchedLLM = nil
            }

            try Task.checkCancellation()

            appState.lastProcessedText = finalText

            // Save to history (with audio for debugging)
            appState.addHistoryRecord(
                rawText: rawText,
                processedText: finalText != rawText ? finalText : nil,
                sttProvider: appState.sttProviderType.rawValue,
                llmProvider: appState.llmEnabled ? appState.llmProviderType.rawValue : nil,
                audioSamples: samples
            )

            // Inject
            appState.dictationState = .injecting
            await TextInjector.inject(finalText, mode: appState.injectionMode)

            appState.dictationState = .idle
            logger.info("Dictation complete")
        } catch is CancellationError {
            logger.info("Pipeline task cancelled")
            cancelPreLaunchedLLM()
            // State already reset by cancelPipeline()
        } catch {
            cancelPreLaunchedLLM()
            logger.error("Dictation failed: \(error.localizedDescription)")
            // Save error to history for debugging
            appState.addHistoryRecord(
                rawText: appState.lastTranscription.isEmpty ? "(no transcription)" : appState.lastTranscription,
                processedText: nil,
                sttProvider: appState.sttProviderType.rawValue,
                llmProvider: appState.llmEnabled ? appState.llmProviderType.rawValue : nil,
                audioSamples: samples,
                errorMessage: error.localizedDescription
            )
            appState.dictationState = .error(error.localizedDescription)
            resetAfterDelay()
        }

        pipelineTask = nil
    }

    // MARK: - Provider creation (always fresh to pick up setting changes)

    private func createSTTProvider() -> any STTProvider {
        switch appState.sttProviderType {
        case .whisperKit:
            WhisperKitSTT(
                modelName: appState.whisperModel,
                language: String(appState.sttLanguage.prefix(2)),
                temperature: appState.whisperTemperature,
                temperatureFallbackCount: appState.whisperTemperatureFallbackCount,
                usePrefillPrompt: appState.whisperUsePrefillPrompt,
                compressionRatioThreshold: appState.whisperCompressionRatioThreshold,
                noSpeechThreshold: appState.whisperNoSpeechThreshold
            )
        case .appleSpeech:
            AppleSpeechSTT(language: appState.sttLanguage)
        case .openAIWhisper:
            OpenAIWhisperSTT(apiKey: appState.openAIAPIKey, baseURL: appState.openAIBaseURL, language: String(appState.sttLanguage.prefix(2)))
        }
    }

    private func createLLMProvider() -> any LLMProvider {
        switch appState.llmProviderType {
        case .claudeCode:
            ClaudeCodeLLM(cliPath: appState.claudeCodeCliPath, model: appState.claudeCodeModel)
        case .codex:
            CodexLLM(cliPath: appState.codexCliPath, model: appState.codexModel)
        case .claude:
            ClaudeLLM(
                apiKey: appState.anthropicAPIKey,
                baseURL: appState.anthropicBaseURL,
                model: appState.claudeModel,
                temperature: appState.llmTemperature,
                maxTokens: appState.llmMaxTokens
            )
        case .openAI:
            OpenAILLM(
                apiKey: appState.openAIAPIKey,
                baseURL: appState.openAIBaseURL,
                model: appState.openAILLMModel,
                temperature: appState.llmTemperature,
                maxTokens: appState.llmMaxTokens
            )
        case .localMLX:
            LocalMLXLLM(modelName: appState.localLLMModel)
        }
    }

    // MARK: - LLM Processing

    private func polishWithLLM(_ text: String, provider: (any LLMProvider)? = nil) async throws -> String {
        let llm = provider ?? createLLMProvider()
        if !(await llm.isReady) {
            try await llm.prepare()
        }

        let messages: [LLMMessage] = [
            .init(role: .system, content: appState.llmSystemPrompt),
            .init(role: .user, content: text)
        ]

        let result = try await llm.process(messages: messages)
        logger.info("LLM polished: \(result.text.prefix(100))...")
        return result.text
    }

    // MARK: - Helpers

    private func resetAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .error = appState.dictationState {
                appState.dictationState = .idle
            }
        }
    }
}
