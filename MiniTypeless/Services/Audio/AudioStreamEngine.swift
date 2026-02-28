@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "AudioStreamEngine")

/// Real-time audio capture using AVAudioEngine with 16kHz mono Float32 output.
///
/// Techniques adopted from proven open-source projects:
/// - **Fresh engine per session** (WhisperKit, super-voice-assistant):
///   Create a new AVAudioEngine() each time to avoid stale HAL I/O state.
/// - **mainMixerNode access** (AudioKit):
///   Force complete audio graph initialization so the HAL I/O proc starts.
/// - **`.noDataNow` instead of `.endOfStream`** (sherpa-onnx):
///   Prevents AVAudioConverter from entering a terminal state between calls.
/// - **Tap format = `inputNode.outputFormat(forBus: 0)`** (all projects):
///   Never pass a custom format to installTap; resample manually in the callback.
final class AudioStreamEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    private var _isCapturing = false
    private var _allSamples: [Float] = []

    /// Called from the audio tap thread with new 16kHz mono Float32 samples.
    var onAudioBuffer: (([Float]) -> Void)?

    /// Called on a background thread with normalized audio level (0.0 to 1.0).
    var audioLevelCallback: ((Float) -> Void)?

    private let targetSampleRate: Double = 16000

    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCapturing
    }

    /// All samples captured so far (for fallback to batch mode).
    var allSamples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return _allSamples
    }

    // MARK: - Start/Stop

    func startCapture() throws {
        lock.lock()
        guard !_isCapturing else { lock.unlock(); return }
        _allSamples = []
        lock.unlock()

        // Create a FRESH engine every time (WhisperKit / super-voice-assistant pattern).
        // This avoids stale HAL I/O thread state from previous sessions.
        let newEngine = AVAudioEngine()
        let inputNode = newEngine.inputNode

        // CRITICAL (AudioKit pattern): Access mainMixerNode to force the engine
        // to build a complete audio graph with a proper HAL I/O proc.
        // Without this, input-only taps can silently fail on macOS.
        let mixer = newEngine.mainMixerNode
        mixer.outputVolume = 0

        // Use the node's output format for the tap (all projects agree on this).
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioStreamError.invalidHardwareFormat
        }

        logger.info("Hardware format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch")

        // Create converter: hardware format → 16kHz mono Float32
        let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let conv = AVAudioConverter(from: hwFormat, to: monoFormat) else {
            throw AudioStreamError.converterCreationFailed
        }
        self.converter = conv

        // Install tap with the hardware format
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            self?.processTapBuffer(buffer)
        }

        newEngine.prepare()

        do {
            try newEngine.start()
        } catch {
            // Retry once after a brief delay (HAL error 35 workaround)
            logger.warning("Engine start failed, retrying in 300ms: \(error.localizedDescription)")
            inputNode.removeTap(onBus: 0)
            newEngine.stop()
            newEngine.reset()
            Thread.sleep(forTimeInterval: 0.3)

            // Rebuild tap and retry
            let retryMixer = newEngine.mainMixerNode
            retryMixer.outputVolume = 0
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
                self?.processTapBuffer(buffer)
            }
            newEngine.prepare()
            try newEngine.start()
        }

        self.engine = newEngine

        lock.lock()
        _isCapturing = true
        lock.unlock()

        logger.info("Audio stream capture started")
    }

    /// Stop capturing and return all accumulated samples.
    @discardableResult
    func stopCapture() -> [Float] {
        lock.lock()
        guard _isCapturing else {
            let samples = _allSamples
            lock.unlock()
            return samples
        }
        _isCapturing = false
        lock.unlock()

        if let eng = engine {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            eng.reset()
        }
        engine = nil
        converter = nil

        lock.lock()
        let samples = _allSamples
        lock.unlock()

        logger.info("Audio stream stopped: \(samples.count) total samples (\(String(format: "%.1f", Double(samples.count) / self.targetSampleRate))s)")
        return samples
    }

    // MARK: - Tap Processing

    private func processTapBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter else { return }

        let ratio = targetSampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: conv.outputFormat,
            frameCapacity: outputCapacity
        ) else { return }

        // Use .noDataNow instead of .endOfStream (sherpa-onnx pattern).
        // This prevents the converter from entering a terminal state,
        // so it works correctly across repeated tap callbacks without reset().
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        conv.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard error == nil, outputBuffer.frameLength > 0,
              let channelData = outputBuffer.floatChannelData else { return }

        let count = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: count))

        // Compute audio level for metering
        if let callback = audioLevelCallback {
            var rms: Float = 0
            for s in samples { rms += s * s }
            rms = sqrt(rms / Float(count))
            let db = 20 * log10(max(rms, 1e-10))
            let minDb: Float = -50
            let normalized = max(0, (db - minDb) / (-minDb))
            callback(min(1, normalized))
        }

        // Accumulate
        lock.lock()
        _allSamples.append(contentsOf: samples)
        lock.unlock()

        // Deliver to callback
        onAudioBuffer?(samples)
    }
}

enum AudioStreamError: LocalizedError {
    case invalidHardwareFormat
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidHardwareFormat:
            "Audio input has invalid format (0Hz or 0 channels)"
        case .converterCreationFailed:
            "Failed to create audio format converter"
        }
    }
}
