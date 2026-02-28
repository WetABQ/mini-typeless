import SwiftUI
import Observation

// MARK: - Pipeline State

enum DictationState: Equatable {
    case idle
    case recording
    case loadingModel
    case transcribing
    case processing
    case injecting
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }

    var statusText: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Recording..."
        case .loadingModel: return "Loading model..."
        case .transcribing: return "Transcribing..."
        case .processing: return "Processing..."
        case .injecting: return "Injecting..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// Pipeline step index for progress display (0-based).
    var stepIndex: Int {
        switch self {
        case .idle, .error: 0
        case .recording: 1
        case .loadingModel: 2
        case .transcribing: 3
        case .processing: 4
        case .injecting: 5
        }
    }
}

// MARK: - History

struct DictationRecord: Identifiable, Codable {
    let id: UUID
    let date: Date
    let rawText: String
    let processedText: String?
    let sttProvider: String
    let llmProvider: String?
    let durationSeconds: Double?
    let audioFileName: String?
    let errorMessage: String?

    init(rawText: String, processedText: String?, sttProvider: String, llmProvider: String?, durationSeconds: Double?, audioFileName: String? = nil, errorMessage: String? = nil) {
        self.id = UUID()
        self.date = Date()
        self.rawText = rawText
        self.processedText = processedText
        self.sttProvider = sttProvider
        self.llmProvider = llmProvider
        self.durationSeconds = durationSeconds
        self.audioFileName = audioFileName
        self.errorMessage = errorMessage
    }

    var audioFileURL: URL? {
        guard let audioFileName else { return nil }
        return DictationRecord.audioDirectory.appendingPathComponent(audioFileName)
    }

    static let audioDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MiniTypeless/AudioHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

// MARK: - App State

@Observable
@MainActor
final class AppState {
    // Pipeline
    var dictationState: DictationState = .idle
    var lastTranscription: String = ""
    var lastProcessedText: String = ""
    var recordingStartTime: Date?

    // Audio metering (transient, not persisted)
    var audioLevel: Float = 0
    var audioLevelHistory: [Float] = Array(repeating: 0, count: 12)

    // WhisperKit model cache tracking (transient, reflects WhisperKitSTT.cachedKit)
    var cachedWhisperModel: String?

    // History
    var history: [DictationRecord] = [] {
        didSet { saveHistory() }
    }

    init() {
        let ud = UserDefaults.standard

        // STT
        if let raw = ud.string(forKey: UDKey.sttProvider), let val = STTProviderType(rawValue: raw) {
            self.sttProviderType = val
        }
        if let val = ud.string(forKey: UDKey.sttLanguage), !val.isEmpty {
            self.sttLanguage = val
        }

        // LLM
        self.llmEnabled = ud.object(forKey: UDKey.llmEnabled) != nil ? ud.bool(forKey: UDKey.llmEnabled) : false
        if let raw = ud.string(forKey: UDKey.llmProvider), let val = LLMProviderType(rawValue: raw) {
            self.llmProviderType = val
        }

        // Injection
        if let raw = ud.string(forKey: UDKey.injectionMode), let val = InjectionMode(rawValue: raw) {
            self.injectionMode = val
        }

        // API Keys
        if let val = ud.string(forKey: UDKey.openAIAPIKey) { self.openAIAPIKey = val }
        if let val = ud.string(forKey: UDKey.anthropicAPIKey) { self.anthropicAPIKey = val }

        // Models
        if let val = ud.string(forKey: UDKey.whisperModel), !val.isEmpty { self.whisperModel = val }
        if let val = ud.string(forKey: UDKey.localLLMModel), !val.isEmpty { self.localLLMModel = val }

        // Prompt
        if let val = ud.string(forKey: UDKey.llmSystemPrompt) { self.llmSystemPrompt = val }

        // Base URLs
        if let val = ud.string(forKey: UDKey.openAIBaseURL) { self.openAIBaseURL = val }
        if let val = ud.string(forKey: UDKey.anthropicBaseURL) { self.anthropicBaseURL = val }

        // WhisperKit decoding options
        if ud.object(forKey: UDKey.whisperTemperature) != nil {
            self.whisperTemperature = ud.float(forKey: UDKey.whisperTemperature)
        }
        if ud.object(forKey: UDKey.whisperTempFallbackCount) != nil {
            self.whisperTemperatureFallbackCount = ud.integer(forKey: UDKey.whisperTempFallbackCount)
        }
        if ud.object(forKey: UDKey.whisperUsePrefillPrompt) != nil {
            self.whisperUsePrefillPrompt = ud.bool(forKey: UDKey.whisperUsePrefillPrompt)
        }
        if ud.object(forKey: UDKey.whisperCompressionRatioThreshold) != nil {
            self.whisperCompressionRatioThreshold = ud.float(forKey: UDKey.whisperCompressionRatioThreshold)
        }
        if ud.object(forKey: UDKey.whisperNoSpeechThreshold) != nil {
            self.whisperNoSpeechThreshold = ud.float(forKey: UDKey.whisperNoSpeechThreshold)
        }

        // LLM parameters
        if let val = ud.string(forKey: UDKey.claudeModel), !val.isEmpty { self.claudeModel = val }
        if let val = ud.string(forKey: UDKey.openAILLMModel), !val.isEmpty { self.openAILLMModel = val }
        if ud.object(forKey: UDKey.llmTemperature) != nil {
            self.llmTemperature = ud.float(forKey: UDKey.llmTemperature)
        }
        if ud.object(forKey: UDKey.llmMaxTokens) != nil {
            self.llmMaxTokens = ud.integer(forKey: UDKey.llmMaxTokens)
        }

        // CLI LLM
        if let val = ud.string(forKey: UDKey.claudeCodeCliPath), !val.isEmpty { self.claudeCodeCliPath = val }
        if let val = ud.string(forKey: UDKey.claudeCodeModel), !val.isEmpty { self.claudeCodeModel = val }
        if let val = ud.string(forKey: UDKey.codexCliPath), !val.isEmpty { self.codexCliPath = val }
        if let val = ud.string(forKey: UDKey.codexModel), !val.isEmpty { self.codexModel = val }

        // Auto-detect CLI paths on first launch
        if ud.string(forKey: UDKey.claudeCodeCliPath) == nil {
            self.claudeCodeCliPath = CLIResolver.findCLI(name: "claude")
        }
        if ud.string(forKey: UDKey.codexCliPath) == nil {
            self.codexCliPath = CLIResolver.findCLI(name: "codex")
        }

        loadHistory()
    }

    func addHistoryRecord(rawText: String, processedText: String?, sttProvider: String, llmProvider: String?, audioSamples: [Float]? = nil, errorMessage: String? = nil) {
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) }

        // Save audio file if samples provided
        var audioFileName: String?
        if let samples = audioSamples, !samples.isEmpty {
            let fileName = "\(UUID().uuidString).wav"
            let fileURL = DictationRecord.audioDirectory.appendingPathComponent(fileName)
            let wavData = AudioConverter.wavData(from: samples)
            do {
                try wavData.write(to: fileURL)
                audioFileName = fileName
            } catch {
                // Non-fatal: history still works without audio
            }
        }

        let record = DictationRecord(
            rawText: rawText,
            processedText: processedText,
            sttProvider: sttProvider,
            llmProvider: llmProvider,
            durationSeconds: duration,
            audioFileName: audioFileName,
            errorMessage: errorMessage
        )
        history.insert(record, at: 0)
        // Keep last 100 entries
        if history.count > 100 {
            // Delete audio files for removed records
            let removed = Array(history.suffix(from: 100))
            for r in removed {
                if let url = r.audioFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            history = Array(history.prefix(100))
        }
    }

    func clearHistory() {
        for record in history {
            if let url = record.audioFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        history = []
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: UDKey.history)
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: UDKey.history),
              let records = try? JSONDecoder().decode([DictationRecord].self, from: data) else { return }
        history = records
    }

    // MARK: - Settings (stored properties for @Observable tracking)

    // STT
    var sttProviderType: STTProviderType = .whisperKit {
        didSet { UserDefaults.standard.set(sttProviderType.rawValue, forKey: UDKey.sttProvider) }
    }

    var sttLanguage: String = "zh-Hans" {
        didSet { UserDefaults.standard.set(sttLanguage, forKey: UDKey.sttLanguage) }
    }

    // LLM
    var llmEnabled: Bool = false {
        didSet { UserDefaults.standard.set(llmEnabled, forKey: UDKey.llmEnabled) }
    }

    var llmProviderType: LLMProviderType = .claude {
        didSet { UserDefaults.standard.set(llmProviderType.rawValue, forKey: UDKey.llmProvider) }
    }

    // Injection
    var injectionMode: InjectionMode = .clipboardAndPaste {
        didSet { UserDefaults.standard.set(injectionMode.rawValue, forKey: UDKey.injectionMode) }
    }

    // API Keys
    var openAIAPIKey: String = "" {
        didSet { UserDefaults.standard.set(openAIAPIKey, forKey: UDKey.openAIAPIKey) }
    }

    var anthropicAPIKey: String = "" {
        didSet { UserDefaults.standard.set(anthropicAPIKey, forKey: UDKey.anthropicAPIKey) }
    }

    // Models
    var whisperModel: String = Defaults.whisperModel {
        didSet { UserDefaults.standard.set(whisperModel, forKey: UDKey.whisperModel) }
    }

    var localLLMModel: String = Defaults.localLLMModel {
        didSet { UserDefaults.standard.set(localLLMModel, forKey: UDKey.localLLMModel) }
    }

    // Prompt
    var llmSystemPrompt: String = Defaults.llmSystemPrompt {
        didSet { UserDefaults.standard.set(llmSystemPrompt, forKey: UDKey.llmSystemPrompt) }
    }

    // Base URLs
    var openAIBaseURL: String = "" {
        didSet { UserDefaults.standard.set(openAIBaseURL, forKey: UDKey.openAIBaseURL) }
    }

    var anthropicBaseURL: String = "" {
        didSet { UserDefaults.standard.set(anthropicBaseURL, forKey: UDKey.anthropicBaseURL) }
    }

    // MARK: - WhisperKit Decoding Options

    var whisperTemperature: Float = Defaults.whisperTemperature {
        didSet { UserDefaults.standard.set(whisperTemperature, forKey: UDKey.whisperTemperature) }
    }

    var whisperTemperatureFallbackCount: Int = Defaults.whisperTempFallbackCount {
        didSet { UserDefaults.standard.set(whisperTemperatureFallbackCount, forKey: UDKey.whisperTempFallbackCount) }
    }

    var whisperUsePrefillPrompt: Bool = Defaults.whisperUsePrefillPrompt {
        didSet { UserDefaults.standard.set(whisperUsePrefillPrompt, forKey: UDKey.whisperUsePrefillPrompt) }
    }

    var whisperCompressionRatioThreshold: Float = Defaults.whisperCompressionRatioThreshold {
        didSet { UserDefaults.standard.set(whisperCompressionRatioThreshold, forKey: UDKey.whisperCompressionRatioThreshold) }
    }

    var whisperNoSpeechThreshold: Float = Defaults.whisperNoSpeechThreshold {
        didSet { UserDefaults.standard.set(whisperNoSpeechThreshold, forKey: UDKey.whisperNoSpeechThreshold) }
    }

    // MARK: - LLM Parameters

    var claudeModel: String = Defaults.claudeModel {
        didSet { UserDefaults.standard.set(claudeModel, forKey: UDKey.claudeModel) }
    }

    var openAILLMModel: String = Defaults.openAILLMModel {
        didSet { UserDefaults.standard.set(openAILLMModel, forKey: UDKey.openAILLMModel) }
    }

    var llmTemperature: Float = Defaults.llmTemperature {
        didSet { UserDefaults.standard.set(llmTemperature, forKey: UDKey.llmTemperature) }
    }

    var llmMaxTokens: Int = Defaults.llmMaxTokens {
        didSet { UserDefaults.standard.set(llmMaxTokens, forKey: UDKey.llmMaxTokens) }
    }

    // MARK: - CLI LLM Providers

    var claudeCodeCliPath: String = Defaults.claudeCodeCliPath {
        didSet { UserDefaults.standard.set(claudeCodeCliPath, forKey: UDKey.claudeCodeCliPath) }
    }

    var claudeCodeModel: String = Defaults.claudeCodeModel {
        didSet { UserDefaults.standard.set(claudeCodeModel, forKey: UDKey.claudeCodeModel) }
    }

    var codexCliPath: String = Defaults.codexCliPath {
        didSet { UserDefaults.standard.set(codexCliPath, forKey: UDKey.codexCliPath) }
    }

    var codexModel: String = Defaults.codexModel {
        didSet { UserDefaults.standard.set(codexModel, forKey: UDKey.codexModel) }
    }
}
