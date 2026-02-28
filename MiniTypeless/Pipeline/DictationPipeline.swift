import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "DictationPipeline")

/// Orchestrates the full dictation flow: record → transcribe → LLM polish → inject.
///
/// For local STT providers (WhisperKit, SenseVoice), uses streaming mode:
/// audio is chunked via VAD during recording and transcribed in parallel.
/// For API providers, uses the original batch mode.
@MainActor
final class DictationPipeline {
    private let appState: AppState
    private let recorder = AudioRecorder()
    private lazy var streamingPipeline = StreamingPipeline(appState: appState)
    private var pipelineTask: Task<Void, Never>?
    private var preLaunchedLLM: (any LLMProvider)?
    private var useStreamingMode = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// Pre-warm everything at app launch to minimize first-recording latency:
    /// 1. AudioRecorder subsystem (for batch mode)
    /// 2. AudioStreamEngine / CoreAudio HAL (for streaming mode)
    /// 3. STT model (load into memory in background)
    func warmUp() {
        Task.detached {
            self.recorder.warmUp()
        }

        // Pre-warm AudioStreamEngine: briefly create and start an engine
        // to initialize CoreAudio HAL, then tear it down.
        Task.detached {
            let engine = AudioStreamEngine()
            do {
                try engine.startCapture()
                // Let it run briefly to fully initialize HAL I/O
                try? await Task.sleep(for: .milliseconds(200))
                engine.stopCapture()
                logger.info("AudioStreamEngine pre-warmed")
            } catch {
                logger.warning("AudioStreamEngine warmup failed (non-fatal): \(error.localizedDescription)")
            }
        }

        // Pre-load STT model in background so first dictation starts instantly
        Task {
            await preloadSTTModel()
        }
    }

    /// Load the currently selected STT model into memory.
    /// Called at app launch and can be called again when the user changes provider/model.
    private func preloadSTTModel() async {
        let provider = appState.sttProviderType
        guard provider.isLocal else { return }

        logger.info("Preloading STT model: \(provider.rawValue)")
        do {
            let stt = createSTTProvider()
            if !(await stt.isReady) {
                try await stt.prepare()
                if provider == .whisperKit {
                    appState.cachedWhisperModel = appState.whisperModel
                } else if provider == .senseVoice {
                    appState.cachedSenseVoiceModel = appState.senseVoiceModel
                }
                logger.info("STT model preloaded: \(provider.rawValue)")
            } else {
                logger.info("STT model already cached: \(provider.rawValue)")
            }
        } catch {
            logger.warning("STT preload failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Public API

    func startDictation() async {
        guard appState.dictationState == .idle else {
            logger.warning("Cannot start dictation: state is \(self.appState.dictationState.statusText)")
            return
        }

        let provider = appState.sttProviderType
        useStreamingMode = provider.isLocal

        do {
            if useStreamingMode {
                // Streaming mode: prepare STT first, then start streaming capture
                appState.dictationState = .loadingModel
                let stt = createSTTProvider()
                if !(await stt.isReady) {
                    try await stt.prepare()
                    if provider == .whisperKit {
                        appState.cachedWhisperModel = appState.whisperModel
                    } else if provider == .senseVoice {
                        appState.cachedSenseVoiceModel = appState.senseVoiceModel
                    }
                }

                appState.dictationState = .recording
                appState.recordingStartTime = Date()

                // Pre-launch CLI LLM during recording for overlap
                if appState.llmEnabled {
                    preLaunchLLM()
                }

                try streamingPipeline.startStreaming(sttProvider: stt)
            } else {
                // Batch mode: record first, process later
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
            }

            logger.info("Dictation started (streaming=\(self.useStreamingMode))")
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

        if useStreamingMode {
            // Streaming mode: stop capture, await chunk STTs, then polish + inject
            pipelineTask = Task {
                await runStreamingPostProcess()
            }
        } else {
            // Batch mode: stop recorder, get samples, run full pipeline
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
    }

    /// Cancel a running transcription/processing pipeline.
    func cancelPipeline() {
        pipelineTask?.cancel()
        pipelineTask = nil

        // Terminate any pre-launched CLI process
        cancelPreLaunchedLLM()

        // Stop recording
        if useStreamingMode {
            streamingPipeline.cancel()
        } else if recorder.recording {
            recorder.audioLevelCallback = nil
            _ = recorder.stopRecording()
        }

        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)
        appState.streamingTranscription = ""
        appState.streamingChunkCount = 0
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

    private func preLaunchLLM() {
        let llm = createLLMProvider()
        let systemPrompt = appState.llmSystemPrompt
        if let claude = llm as? ClaudeCodeLLM {
            claude.warmUp(systemPrompt: systemPrompt)
            logger.info("Pre-launched Claude CLI during streaming")
        } else if let codex = llm as? CodexLLM {
            codex.warmUp(systemPrompt: systemPrompt)
            logger.info("Pre-launched Codex CLI during streaming")
        }
        preLaunchedLLM = llm
    }

    // MARK: - Streaming post-processing

    /// Called after streaming recording stops. Awaits all chunks,
    /// polishes, and injects.
    private func runStreamingPostProcess() async {
        do {
            appState.dictationState = .transcribing
            let result = await streamingPipeline.stopStreaming()

            try Task.checkCancellation()

            let rawText = result.text
            logger.info("Streaming result: \(result.chunkCount) chunks, text='\(rawText.prefix(200))'")

            guard !rawText.isEmpty else {
                logger.info("Empty streaming transcription")
                cancelPreLaunchedLLM()
                appState.dictationState = .error("No speech detected")
                resetAfterDelay()
                return
            }

            appState.lastTranscription = rawText

            // LLM polish (optional)
            var finalText = rawText
            if appState.llmEnabled {
                appState.dictationState = .processing
                try Task.checkCancellation()
                finalText = try await polishWithLLM(rawText, provider: preLaunchedLLM)
                preLaunchedLLM = nil
            }

            try Task.checkCancellation()

            appState.lastProcessedText = finalText
            appState.streamingTranscription = ""
            appState.streamingChunkCount = 0

            // Save to history
            appState.addHistoryRecord(
                rawText: rawText,
                processedText: finalText != rawText ? finalText : nil,
                sttProvider: appState.sttProviderType.rawValue,
                llmProvider: appState.llmEnabled ? appState.llmProviderType.rawValue : nil,
                audioSamples: result.allSamples
            )

            // Inject
            appState.dictationState = .injecting
            await TextInjector.inject(finalText, mode: appState.injectionMode)

            appState.dictationState = .idle
            logger.info("Streaming dictation complete")
        } catch is CancellationError {
            logger.info("Streaming pipeline cancelled")
            cancelPreLaunchedLLM()
        } catch {
            cancelPreLaunchedLLM()
            logger.error("Streaming dictation failed: \(error.localizedDescription)")
            appState.dictationState = .error(error.localizedDescription)
            resetAfterDelay()
        }

        pipelineTask = nil
    }

    // MARK: - Batch pipeline execution

    private func runPipeline(samples: [Float]) async {
        let provider = appState.sttProviderType
        logger.info("runPipeline: starting with \(samples.count) samples, provider=\(provider.rawValue)")

        do {
            try Task.checkCancellation()

            let stt = createSTTProvider()

            // Only show "Loading model" for local model providers (WhisperKit, SenseVoice).
            // API providers (OpenAI) and Apple Speech don't load a model.
            if provider.isLocal {
                appState.dictationState = .loadingModel
                logger.info("runPipeline: checking \(provider.rawValue) isReady...")
                if !(await stt.isReady) {
                    logger.info("runPipeline: \(provider.rawValue) not ready, calling prepare()...")
                    try await stt.prepare()
                    if provider == .whisperKit {
                        appState.cachedWhisperModel = appState.whisperModel
                    } else if provider == .senseVoice {
                        appState.cachedSenseVoiceModel = appState.senseVoiceModel
                    }
                    logger.info("runPipeline: \(provider.rawValue) prepare() completed")
                } else {
                    logger.info("runPipeline: \(provider.rawValue) already ready (cached)")
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
        case .senseVoice:
            SenseVoiceSTT(modelName: appState.senseVoiceModel, language: String(appState.sttLanguage.prefix(2)))
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
        let startTime = Date()
        let llm = provider ?? createLLMProvider()
        let isPreLaunched = provider != nil
        logger.info("LLM polish starting (provider=\(llm.displayName), preLaunched=\(isPreLaunched), textLen=\(text.count))")

        if !(await llm.isReady) {
            try await llm.prepare()
        }

        let messages: [LLMMessage] = [
            .init(role: .system, content: appState.llmSystemPrompt),
            .init(role: .user, content: text)
        ]

        let result = try await llm.process(messages: messages)
        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("LLM polished in \(String(format: "%.1f", elapsed))s (\(llm.displayName)): \(result.text.prefix(100))...")
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
