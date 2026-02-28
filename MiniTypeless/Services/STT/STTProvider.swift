import Foundation

struct TranscriptionResult: Sendable {
    let text: String
    let language: String?
    let duration: TimeInterval?
}

protocol STTProvider: Sendable {
    var displayName: String { get }
    var requiresNetwork: Bool { get }
    var isReady: Bool { get async }
    func prepare() async throws
    func transcribe(audioSamples: [Float]) async throws -> TranscriptionResult
    func transcribe(fileURL: URL) async throws -> TranscriptionResult
}
