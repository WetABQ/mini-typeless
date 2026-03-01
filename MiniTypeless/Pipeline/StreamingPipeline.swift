import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "StreamingPipeline")

/// Streaming dictation pipeline for local STT providers.
///
/// During recording, audio is chunked via VAD and each chunk is
/// transcribed in parallel. Per-chunk LLM polish runs concurrently
/// with recording so results are ready by the time the user stops.
///
/// Architecture:
/// ```
/// [Recording + VAD chunking]
///   chunk0 → [STT] → [LLM polish] → chunk0P
///   chunk1 → [STT] → [LLM polish with context] → chunk1P
///   (stop) → flush → await STT → await LLM (with timeout) → join
/// ```
@MainActor
final class StreamingPipeline {
    private let appState: AppState
    private let audioEngine = AudioStreamEngine()
    private let chunker = VADChunker()

    /// Ordered chunk transcription results. Index = chunk order.
    private var chunkResults: [Int: String] = [:]
    private var nextChunkIndex: Int = 0
    private var activeTasks: [Task<Void, Never>] = []
    private var sttProvider: (any STTProvider)?
    private var isCancelled = false

    // Per-chunk LLM polish state
    private var llmFactory: (() -> any LLMProvider)?
    private var llmSystemPrompt: String = ""
    private var chunkPolishedResults: [Int: String] = [:]
    private var nextLLMChunkIndex: Int = 0
    private var activeLLMTasks: [Task<Void, Never>] = []
    private var completedLLMTaskCount: Int = 0
    private var warmLLMProviders: [Int: any LLMProvider] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start Streaming

    /// Begin streaming capture. Prepares STT, starts audio engine,
    /// and begins chunking audio for parallel transcription.
    /// Optionally accepts an LLM factory for incremental polish during recording.
    func startStreaming(
        sttProvider: any STTProvider,
        llmFactory: (() -> any LLMProvider)? = nil,
        llmSystemPrompt: String = ""
    ) throws {
        self.sttProvider = sttProvider
        self.chunkResults = [:]
        self.nextChunkIndex = 0
        self.activeTasks = []
        self.isCancelled = false
        chunker.reset()

        // Reset LLM state
        self.llmFactory = llmFactory
        self.llmSystemPrompt = llmSystemPrompt
        self.chunkPolishedResults = [:]
        self.nextLLMChunkIndex = 0
        self.activeLLMTasks = []
        self.completedLLMTaskCount = 0
        self.warmLLMProviders = [:]

        appState.streamingTranscription = ""
        appState.streamingChunkCount = 0

        // Wire audio level metering
        let state = appState
        audioEngine.audioLevelCallback = { level in
            Task { @MainActor in
                state.audioLevel = level
                state.audioLevelHistory.append(level)
                if state.audioLevelHistory.count > 12 {
                    state.audioLevelHistory.removeFirst()
                }
            }
        }

        // Wire audio buffer callback → VAD chunker → STT task
        audioEngine.onAudioBuffer = { [weak self] samples in
            guard let self, !self.isCancelled else { return }
            if let chunk = self.chunker.feed(samples: samples) {
                let index = self.nextChunkIndex
                self.nextChunkIndex += 1
                self.dispatchChunkTranscription(chunk, index: index)
            }
        }

        try audioEngine.startCapture()
        logger.info("Streaming pipeline started")
    }

    // MARK: - Stop Streaming (Phase 1: STT)

    /// Stop recording, flush remaining audio, await all STT tasks.
    /// Returns raw transcription. LLM polish tasks may still be running.
    func stopAndFinishSTT() async -> StreamingRawResult {
        audioEngine.audioLevelCallback = nil
        audioEngine.onAudioBuffer = nil
        let allSamples = audioEngine.stopCapture()

        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)

        // Flush remaining audio from chunker
        if let lastChunk = chunker.flush() {
            let index = nextChunkIndex
            nextChunkIndex += 1
            dispatchChunkTranscription(lastChunk, index: index)
        }

        // Wait for all STT tasks to complete
        for task in activeTasks {
            await task.value
        }

        // Trigger LLM polish for any chunks not yet queued
        tryTriggerPendingPolishes()

        // Join raw results in order
        let totalChunks = nextChunkIndex
        var parts: [String] = []
        for i in 0..<totalChunks {
            if let text = chunkResults[i], !text.isEmpty {
                parts.append(text)
            }
        }

        let joinedText = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("STT complete: \(totalChunks) chunks → '\(joinedText.prefix(200))'")

        return StreamingRawResult(
            text: joinedText,
            chunkCount: totalChunks,
            allSamples: allSamples
        )
    }

    // MARK: - Stop Streaming (Phase 2: LLM Polish)

    /// Await LLM polish tasks with a timeout.
    /// Returns polished text if all chunks completed, nil otherwise.
    func awaitPolish(timeout: Duration = .seconds(15)) async -> String? {
        guard !activeLLMTasks.isEmpty else { return nil }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let expected = activeLLMTasks.count

        // Poll for completion with deadline
        while completedLLMTaskCount < expected {
            if ContinuousClock.now >= deadline {
                logger.warning("LLM polish timeout: \(self.completedLLMTaskCount)/\(expected) complete")
                for task in activeLLMTasks {
                    task.cancel()
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }

        cancelWarmLLMProviders()

        // Collect polished results
        let totalChunks = nextChunkIndex
        var polishedParts: [String] = []
        var allPolished = true

        for i in 0..<totalChunks {
            if let polished = chunkPolishedResults[i], !polished.isEmpty {
                polishedParts.append(polished)
            } else if let raw = chunkResults[i], !raw.isEmpty {
                // Chunk had raw text but no polish result
                allPolished = false
            }
        }

        guard allPolished else {
            logger.info("LLM polish incomplete: \(self.chunkPolishedResults.count)/\(totalChunks) chunks polished")
            return nil
        }

        let polishedText = polishedParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("LLM polish complete: '\(polishedText.prefix(200))'")
        return polishedText
    }

    // MARK: - Cancel

    func cancel() {
        isCancelled = true
        audioEngine.audioLevelCallback = nil
        audioEngine.onAudioBuffer = nil
        audioEngine.stopCapture()
        for task in activeTasks {
            task.cancel()
        }
        activeTasks = []
        for task in activeLLMTasks {
            task.cancel()
        }
        activeLLMTasks = []
        chunkPolishedResults = [:]
        cancelWarmLLMProviders()
        chunker.reset()
        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)
        logger.info("Streaming pipeline cancelled")
    }

    // MARK: - Private

    /// Check if there are consecutive chunks ready for LLM polish and dispatch them.
    /// Each chunk is polished independently with all previous raw chunks as context.
    private func tryTriggerPendingPolishes() {
        guard let factory = llmFactory, !isCancelled else { return }

        // Process consecutive chunks that have STT results
        while let rawText = chunkResults[nextLLMChunkIndex] {
            let index = nextLLMChunkIndex
            nextLLMChunkIndex += 1

            // Skip empty chunks (hallucination-filtered)
            guard !rawText.isEmpty else { continue }

            // Gather context: raw text of all previous chunks
            var contextParts: [String] = []
            for i in 0..<index {
                if let t = chunkResults[i], !t.isEmpty {
                    contextParts.append(t)
                }
            }

            dispatchChunkPolish(
                chunkIndex: index,
                rawText: rawText,
                context: contextParts,
                factory: factory
            )
        }
    }

    /// Polish a single chunk with context from all previous raw chunks.
    /// Uses a pre-warmed provider if available (launched when STT was dispatched).
    private func dispatchChunkPolish(
        chunkIndex: Int,
        rawText: String,
        context: [String],
        factory: () -> any LLMProvider
    ) {
        let systemPrompt = llmSystemPrompt
        let provider = warmLLMProviders.removeValue(forKey: chunkIndex) ?? factory()

        // Build user message with <context> tags for multi-chunk scenarios
        let userMessage: String
        if context.isEmpty {
            userMessage = rawText
        } else {
            let contextText = context.joined(separator: "\n")
            userMessage = "<context>\n\(contextText)\n</context>\n\(rawText)"
        }

        let messages: [LLMMessage] = [
            .init(role: .system, content: systemPrompt),
            .init(role: .user, content: userMessage)
        ]

        let task = Task {
            defer { self.completedLLMTaskCount += 1 }
            do {
                if !(await provider.isReady) {
                    try await provider.prepare()
                }
                let result = try await provider.process(messages: messages)
                guard !self.isCancelled else { return }
                self.chunkPolishedResults[chunkIndex] = result.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                logger.info("Chunk #\(chunkIndex) polished: '\(result.text.prefix(100))'")
            } catch {
                if !Task.isCancelled {
                    logger.warning("Chunk #\(chunkIndex) polish failed: \(error.localizedDescription)")
                }
            }
        }

        activeLLMTasks.append(task)
    }

    /// Cancel and clean up any unused warm LLM providers.
    private func cancelWarmLLMProviders() {
        for (_, provider) in warmLLMProviders {
            if let claude = provider as? ClaudeCodeLLM {
                claude.cancelWarm()
            } else if let codex = provider as? CodexLLM {
                codex.cancelWarm()
            }
        }
        warmLLMProviders = [:]
    }

    private func dispatchChunkTranscription(_ chunk: [Float], index: Int) {
        guard let stt = sttProvider else { return }

        // Pre-warm an LLM provider for this chunk (will be ready by the time STT finishes)
        if let factory = llmFactory {
            warmLLMProviders[index] = factory()
        }

        let chunkDuration = Double(chunk.count) / 16000.0
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            do {
                let result = try await stt.transcribe(audioSamples: chunk)
                var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                // Post-STT hallucination filter: very short results from long chunks
                // are almost certainly noise hallucinations (e.g. "我", "Oh")
                if chunkDuration > 2.0 && text.count <= 2 {
                    logger.info("Chunk #\(index) filtered as hallucination: '\(text)' from \(String(format: "%.1f", chunkDuration))s chunk")
                    text = ""
                }

                await MainActor.run {
                    self.chunkResults[index] = text
                    self.appState.streamingChunkCount = self.chunkResults.count

                    // Update live transcription preview
                    var parts: [String] = []
                    for i in 0..<self.nextChunkIndex {
                        if let t = self.chunkResults[i], !t.isEmpty {
                            parts.append(t)
                        }
                    }
                    self.appState.streamingTranscription = parts.joined(separator: " ")

                    // Trigger LLM polish for any consecutive chunks now ready
                    self.tryTriggerPendingPolishes()
                }

                logger.info("Chunk #\(index) transcribed: '\(text.prefix(100))'")
            } catch {
                if !Task.isCancelled {
                    logger.error("Chunk #\(index) transcription failed: \(error.localizedDescription)")
                }
            }
        }

        activeTasks.append(task)
    }
}

struct StreamingRawResult {
    let text: String
    let chunkCount: Int
    let allSamples: [Float]
}
