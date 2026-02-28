import Foundation
import AVFoundation

/// Utility for converting audio samples to WAV format for API upload.
enum AudioConverter {

    /// Creates a WAV file from Float32 samples at 16kHz mono.
    static func wavData(from samples: [Float], sampleRate: Int = 16000) -> Data {
        let bytesPerSample = 2 // 16-bit PCM
        let dataSize = samples.count * bytesPerSample
        let fileSize = 44 + dataSize // WAV header is 44 bytes

        var data = Data()
        data.reserveCapacity(fileSize)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(fileSize - 8)))
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndianUInt32(16)) // chunk size
        data.append(littleEndianUInt16(1))  // PCM format
        data.append(littleEndianUInt16(1))  // mono
        data.append(littleEndianUInt32(UInt32(sampleRate)))
        data.append(littleEndianUInt32(UInt32(sampleRate * bytesPerSample))) // byte rate
        data.append(littleEndianUInt16(UInt16(bytesPerSample))) // block align
        data.append(littleEndianUInt16(16)) // bits per sample

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndianUInt32(UInt32(dataSize)))

        // Convert Float32 [-1,1] to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            data.append(littleEndianInt16(int16Value))
        }

        return data
    }

    /// Writes WAV data to a temporary file and returns its URL.
    static func writeTemporaryWAV(samples: [Float], sampleRate: Int = 16000) throws -> URL {
        let data = wavData(from: samples, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try data.write(to: url)
        return url
    }

    // MARK: - Little-endian helpers

    private static func littleEndianUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func littleEndianUInt16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func littleEndianInt16(_ value: Int16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
