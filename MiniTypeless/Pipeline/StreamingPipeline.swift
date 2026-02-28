import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "StreamingPipeline")

/// Streaming dictation pipeline for local STT providers.
///
/// During recording, audio is chunked via VAD and each chunk is
/// transcribed in parallel. When recording stops, the final chunk
/// is flushed, all transcriptions are joined, optionally polished
/// via LLM, and then injected.
///
/// Architecture:
/// ```
/// [Recording + VAD chunking]
///   chunk1 → [STT task] → ✓ result1
///   chunk2 → [STT task] → ✓ result2
///   chunk3 → [STT task] → ...
///   (stop) → flush last chunk → await all → join → [LLM polish] → inject
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

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Start Streaming

    /// Begin streaming capture. Prepares STT, starts audio engine,
    /// and begins chunking audio for parallel transcription.
    func startStreaming(sttProvider: any STTProvider) throws {
        self.sttProvider = sttProvider
        self.chunkResults = [:]
        self.nextChunkIndex = 0
        self.activeTasks = []
        self.isCancelled = false
        chunker.reset()

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

    // MARK: - Stop Streaming

    /// Stop recording, flush remaining audio, await all STT tasks,
    /// and return the joined transcription.
    func stopStreaming() async -> StreamingResult {
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

        // Join results in order
        let totalChunks = nextChunkIndex
        var parts: [String] = []
        for i in 0..<totalChunks {
            if let text = chunkResults[i], !text.isEmpty {
                parts.append(text)
            }
        }

        let joinedText = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logger.info("Streaming complete: \(totalChunks) chunks → '\(joinedText.prefix(200))'")

        return StreamingResult(
            text: joinedText,
            chunkCount: totalChunks,
            allSamples: allSamples
        )
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
        chunker.reset()
        appState.audioLevel = 0
        appState.audioLevelHistory = Array(repeating: 0, count: 12)
        logger.info("Streaming pipeline cancelled")
    }

    // MARK: - Private

    private func dispatchChunkTranscription(_ chunk: [Float], index: Int) {
        guard let stt = sttProvider else { return }

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

struct StreamingResult {
    let text: String
    let chunkCount: Int
    let allSamples: [Float]
}
