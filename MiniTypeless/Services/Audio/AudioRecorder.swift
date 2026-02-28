@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "AudioRecorder")

/// Records microphone audio and outputs 16kHz mono Float32 samples.
///
/// Uses `AVAudioRecorder` (backed by Audio Queue Services) instead of `AVAudioEngine`.
/// AVAudioEngine's HAL I/O thread can fail silently with error 35 ("there already is a thread"),
/// causing the tap callback to never fire. AVAudioRecorder uses a completely different CoreAudio
/// path that properly manages device lifecycle.
final class AudioRecorder: @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var _isRecording = false
    private let lock = NSLock()
    private var meteringTimer: Timer?

    /// Callback invoked on the main thread with normalized audio level (0.0 to 1.0).
    /// Set before calling startRecording().
    var audioLevelCallback: (@Sendable (Float) -> Void)?

    private let targetSampleRate: Double = 16000

    nonisolated(unsafe) private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 48000.0,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
    ]

    private static var tempFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-typeless-recording.wav")
    }

    // MARK: - Warm-up

    /// Pre-warm the CoreAudio subsystem so the first real recording starts instantly.
    /// Creates a throwaway AVAudioRecorder, calls prepareToRecord(), then discards it.
    /// Safe to call from any thread. Non-fatal on failure.
    func warmUp() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mini-typeless-warmup.wav")

        do {
            let warmup = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            warmup.prepareToRecord()
            warmup.stop()
            try? FileManager.default.removeItem(at: url)
            logger.info("Audio subsystem warmed up")
        } catch {
            logger.warning("Warm-up failed (non-fatal): \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    func startRecording() throws {
        lock.lock()
        guard !_isRecording else { lock.unlock(); return }

        let url = Self.tempFileURL
        try? FileManager.default.removeItem(at: url)

        let rec: AVAudioRecorder
        do {
            rec = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        } catch {
            lock.unlock()
            logger.error("Failed to create AVAudioRecorder: \(error.localizedDescription)")
            throw AudioRecorderError.invalidAudioFormat
        }

        rec.isMeteringEnabled = true
        rec.prepareToRecord()
        guard rec.record() else {
            lock.unlock()
            logger.error("AVAudioRecorder.record() returned false")
            throw AudioRecorderError.invalidAudioFormat
        }

        recorder = rec
        _isRecording = true
        lock.unlock()

        // Start metering timer on main run loop
        let callback = audioLevelCallback
        if callback != nil {
            DispatchQueue.main.async { [weak self] in
                self?.meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock()
                    let rec = self.recorder
                    let recording = self._isRecording
                    self.lock.unlock()

                    guard recording, let rec else { return }
                    rec.updateMeters()
                    let power = rec.averagePower(forChannel: 0) // dB: -160 to 0
                    let minDb: Float = -50
                    let clampedDb = max(minDb, min(0, power))
                    let normalized = (clampedDb - minDb) / (-minDb)
                    callback?(normalized)
                }
            }
        }

        logger.info("Recording started (AVAudioRecorder, 48kHz 16-bit mono, metering=\(callback != nil))")
    }

    func stopRecording() -> [Float] {
        // Invalidate metering timer first
        DispatchQueue.main.async { [weak self] in
            self?.meteringTimer?.invalidate()
            self?.meteringTimer = nil
        }

        lock.lock()
        guard _isRecording, let rec = recorder else {
            logger.warning("stopRecording: not recording")
            lock.unlock()
            return []
        }
        _isRecording = false
        recorder = nil
        lock.unlock()

        rec.stop()
        let url = rec.url

        logger.info("Recording stopped, file at \(url.lastPathComponent)")

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        // Read recorded file → convert to 16kHz mono Float32
        let samples = Self.readAndResample(fileURL: url, targetRate: targetSampleRate)
        logger.info("Output: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / self.targetSampleRate))s at 16kHz)")
        return samples
    }

    var recording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRecording
    }

    // MARK: - File reading & resampling

    /// Read a WAV file and convert to mono Float32 at the target sample rate.
    private static func readAndResample(fileURL: URL, targetRate: Double) -> [Float] {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            logger.error("Failed to open recorded file: \(error.localizedDescription)")
            return []
        }

        let sourceRate = audioFile.fileFormat.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)
        logger.info("Recorded file: \(frameCount) frames at \(sourceRate)Hz, channels=\(audioFile.fileFormat.channelCount)")

        guard frameCount > 0 else {
            logger.error("Recorded file has 0 frames")
            return []
        }

        let processingFormat = audioFile.processingFormat

        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
            logger.error("Failed to allocate read buffer (\(frameCount) frames)")
            return []
        }

        do {
            try audioFile.read(into: buffer)
        } catch {
            logger.error("Failed to read audio file: \(error.localizedDescription)")
            return []
        }

        guard let channelData = buffer.floatChannelData else {
            logger.error("No float channel data in buffer")
            return []
        }

        let readFrames = Int(buffer.frameLength)
        let channelCount = Int(processingFormat.channelCount)

        var monoSamples: [Float]
        if channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: readFrames))
        } else {
            monoSamples = [Float](repeating: 0, count: readFrames)
            for ch in 0..<channelCount {
                let chPtr = channelData[ch]
                for i in 0..<readFrames {
                    monoSamples[i] += chPtr[i]
                }
            }
            let scale = 1.0 / Float(channelCount)
            for i in 0..<readFrames {
                monoSamples[i] *= scale
            }
        }

        let peak = monoSamples.max(by: { abs($0) < abs($1) }).map { abs($0) } ?? 0
        logger.info("Read \(readFrames) mono samples at \(sourceRate)Hz, peak=\(peak)")

        if abs(sourceRate - targetRate) < 1.0 {
            return monoSamples
        }

        return resample(monoSamples, from: sourceRate, to: targetRate)
    }

    /// Resample Float32 mono audio from one sample rate to another using AVAudioConverter.
    private static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        )!

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        )!

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            logger.error("Failed to create converter \(sourceRate) → \(targetRate)")
            return []
        }

        let inputFrameCount = AVAudioFrameCount(samples.count)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrameCount) else {
            logger.error("Failed to allocate input buffer (\(inputFrameCount) frames)")
            return []
        }
        inputBuffer.frameLength = inputFrameCount
        _ = samples.withUnsafeBufferPointer { ptr in
            memcpy(inputBuffer.floatChannelData![0], ptr.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }

        let ratio = targetRate / sourceRate
        let outputCapacity = AVAudioFrameCount(Double(inputFrameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            logger.error("Failed to allocate output buffer (\(outputCapacity) frames)")
            return []
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            outStatus.pointee = .endOfStream
            return nil
        }

        if let error {
            logger.error("Conversion error: \(error.localizedDescription)")
            return []
        }

        guard let outputData = outputBuffer.floatChannelData else { return [] }
        let outputCount = Int(outputBuffer.frameLength)
        let result = Array(UnsafeBufferPointer(start: outputData[0], count: outputCount))

        logger.info("Resampled: \(samples.count) frames at \(sourceRate)Hz → \(outputCount) frames at \(targetRate)Hz")
        return result
    }
}

enum AudioRecorderError: LocalizedError {
    case converterCreationFailed
    case invalidAudioFormat

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return "Failed to create audio format converter"
        case .invalidAudioFormat:
            return "Audio input has invalid format (0Hz or 0 channels)"
        }
    }
}
