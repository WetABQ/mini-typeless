import Foundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "VADChunker")

/// Energy-based voice activity detection and audio chunking.
///
/// Splits a continuous stream of 16kHz Float32 audio into chunks
/// based on silence detection. Used by StreamingPipeline to feed
/// chunks to STT providers as they become available during recording.
///
/// Uses two energy thresholds:
/// - **silenceThresholdDB** (-40dB): Low bar for detecting pauses → triggers chunk splitting
/// - **speechThresholdDB** (-30dB): Higher bar for confirming human speech → gates chunk emission
///
/// Chunks without sufficient speech energy are discarded to prevent
/// STT hallucination on background noise.
final class VADChunker {
    struct Config {
        /// RMS power below this dB level is considered silence (for chunk splitting).
        var silenceThresholdDB: Float = -40

        /// RMS power above this dB level is considered speech (for chunk validation).
        /// Higher than silenceThresholdDB to filter background noise that isn't speech.
        var speechThresholdDB: Float = -30

        /// Minimum fraction of frames that must contain speech to emit a chunk.
        /// Chunks below this ratio are discarded as noise.
        var minSpeechRatio: Float = 0.08

        /// Milliseconds of continuous silence before cutting a chunk.
        var silenceDurationMs: Int = 500

        /// Maximum chunk duration in ms (force-cut even without silence).
        var maxChunkDurationMs: Int = 15000

        /// Minimum chunk duration in ms (too short chunks are kept in buffer).
        var minChunkDurationMs: Int = 500

        /// Sample rate of input audio.
        var sampleRate: Int = 16000
    }

    private let config: Config
    private var buffer: [Float] = []
    private var silenceSampleCount: Int = 0
    private var chunkIndex: Int = 0

    // Speech presence tracking
    private var speechFrameCount: Int = 0
    private var totalFrameCount: Int = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Feed new audio samples. Returns a chunk if a split point is detected.
    /// Returns nil if no split point yet, or if the chunk was discarded (no speech).
    func feed(samples: [Float]) -> [Float]? {
        buffer.append(contentsOf: samples)

        // Compute RMS energy of the incoming frame
        let rms = computeRMS(samples)
        let db = 20 * log10(max(rms, 1e-10))

        // Track silence (for chunk splitting)
        if db < config.silenceThresholdDB {
            silenceSampleCount += samples.count
        } else {
            silenceSampleCount = 0
        }

        // Track speech presence (for chunk validation)
        totalFrameCount += 1
        if db > config.speechThresholdDB {
            speechFrameCount += 1
        }

        let silenceThresholdSamples = config.silenceDurationMs * config.sampleRate / 1000
        let minSamples = config.minChunkDurationMs * config.sampleRate / 1000
        let maxSamples = config.maxChunkDurationMs * config.sampleRate / 1000

        // Force cut if buffer exceeds max duration
        if buffer.count >= maxSamples {
            return emitChunkIfHasSpeech()
        }

        // Cut on silence if buffer is long enough
        if silenceSampleCount >= silenceThresholdSamples && buffer.count >= minSamples {
            return emitChunkIfHasSpeech()
        }

        return nil
    }

    /// Flush remaining buffer (call when recording stops).
    /// Always emits without speech check — user explicitly stopped recording,
    /// so remaining audio should always be transcribed.
    func flush() -> [Float]? {
        guard !buffer.isEmpty else { return nil }
        return emitChunkAlways()
    }

    /// Reset state for a new recording session.
    func reset() {
        buffer = []
        silenceSampleCount = 0
        chunkIndex = 0
        speechFrameCount = 0
        totalFrameCount = 0
    }

    // MARK: - Private

    /// Emit chunk unconditionally (used by flush on recording stop).
    private func emitChunkAlways() -> [Float] {
        let chunk = buffer
        let duration = Double(chunk.count) / Double(config.sampleRate)

        buffer = []
        silenceSampleCount = 0
        speechFrameCount = 0
        totalFrameCount = 0

        logger.info("Chunk #\(self.chunkIndex) flushed: \(chunk.count) samples (\(String(format: "%.1f", duration))s)")
        chunkIndex += 1
        return chunk
    }

    /// Emit chunk only if it contains enough speech energy.
    private func emitChunkIfHasSpeech() -> [Float]? {
        let speechRatio = totalFrameCount > 0
            ? Float(speechFrameCount) / Float(totalFrameCount)
            : 0

        let chunk = buffer
        let duration = Double(chunk.count) / Double(config.sampleRate)

        // Reset buffer state
        buffer = []
        silenceSampleCount = 0
        speechFrameCount = 0
        totalFrameCount = 0

        if speechRatio < config.minSpeechRatio {
            logger.info("Chunk #\(self.chunkIndex) discarded (no speech): \(chunk.count) samples (\(String(format: "%.1f", duration))s), speechRatio=\(String(format: "%.2f", speechRatio))")
            chunkIndex += 1
            return nil
        }

        logger.info("Chunk #\(self.chunkIndex) emitted: \(chunk.count) samples (\(String(format: "%.1f", duration))s), speechRatio=\(String(format: "%.2f", speechRatio))")
        chunkIndex += 1
        return chunk
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }
}
