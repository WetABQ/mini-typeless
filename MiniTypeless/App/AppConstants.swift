import Foundation
@preconcurrency import KeyboardShortcuts

// MARK: - UserDefaults Keys

enum UDKey {
    static let sttProvider = "sttProvider"
    static let llmProvider = "llmProvider"
    static let llmEnabled = "llmEnabled"
    static let openAIAPIKey = "openAIAPIKey"
    static let anthropicAPIKey = "anthropicAPIKey"
    static let whisperModel = "whisperModel"
    static let localLLMModel = "localLLMModel"
    static let llmSystemPrompt = "llmSystemPrompt"
    static let injectionMode = "injectionMode"
    static let launchAtLogin = "launchAtLogin"
    static let openAIBaseURL = "openAIBaseURL"
    static let anthropicBaseURL = "anthropicBaseURL"
    static let sttLanguage = "sttLanguage"
    static let history = "dictationHistory"

    // WhisperKit decoding options
    static let whisperTemperature = "whisperTemperature"
    static let whisperTempFallbackCount = "whisperTempFallbackCount"
    static let whisperUsePrefillPrompt = "whisperUsePrefillPrompt"
    static let whisperCompressionRatioThreshold = "whisperCompressionRatioThreshold"
    static let whisperNoSpeechThreshold = "whisperNoSpeechThreshold"

    // LLM parameters
    static let claudeModel = "claudeModel"
    static let openAILLMModel = "openAILLMModel"
    static let llmTemperature = "llmTemperature"
    static let llmMaxTokens = "llmMaxTokens"

    // CLI LLM providers
    static let claudeCodeCliPath = "claudeCodeCliPath"
    static let claudeCodeModel = "claudeCodeModel"
    static let codexCliPath = "codexCliPath"
    static let codexModel = "codexModel"
}

// MARK: - Default Values

enum Defaults {
    static let whisperModel = "openai_whisper-large-v3_turbo"
    static let localLLMModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    static let llmSystemPrompt = """
    You are a speech-to-text polishing assistant. The user will provide raw transcription output \
    in any language. Clean it up: fix grammar, remove filler words and repetitions, improve \
    punctuation, and make it read naturally. Keep the SAME language as the input — do NOT translate. \
    Preserve the original meaning and tone. Output ONLY the polished text, nothing else.
    """

    // WhisperKit decoding options
    static let whisperTemperature: Float = 0.0
    static let whisperTempFallbackCount: Int = 3
    static let whisperUsePrefillPrompt: Bool = true
    static let whisperCompressionRatioThreshold: Float = 2.8
    static let whisperNoSpeechThreshold: Float = 0.5

    // LLM parameters
    static let claudeModel = "claude-sonnet-4-20250514"
    static let openAILLMModel = "gpt-4o"
    static let llmTemperature: Float = 0.3
    static let llmMaxTokens: Int = 4096

    // CLI LLM defaults (paths auto-detected via CLIResolver on first launch)
    static let claudeCodeCliPath = ""
    static let claudeCodeModel = "sonnet"
    static let codexCliPath = ""
    static let codexModel = "gpt-5.3-codex"

    // Supported languages for STT
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("es-ES", "Spanish"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("it-IT", "Italian"),
        ("ru-RU", "Russian"),
        ("ar-SA", "Arabic"),
        ("hi-IN", "Hindi"),
        ("th-TH", "Thai"),
        ("vi-VN", "Vietnamese"),
        ("nl-NL", "Dutch"),
        ("pl-PL", "Polish"),
        ("sv-SE", "Swedish"),
        ("tr-TR", "Turkish"),
    ]

    // Claude API models
    static let claudeModels = [
        "claude-sonnet-4-20250514",
        "claude-opus-4-20250514",
        "claude-haiku-4-20250514",
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
    ]

    // Whisper model metadata
    static let whisperModels: [WhisperModelInfo] = [
        .init(id: "openai_whisper-tiny", name: "Tiny", sizeMB: 75, description: "Fastest, lowest accuracy. English only recommended."),
        .init(id: "openai_whisper-base", name: "Base", sizeMB: 140, description: "Fast, basic accuracy. Struggles with non-English."),
        .init(id: "openai_whisper-small", name: "Small", sizeMB: 460, description: "Good balance for most languages."),
        .init(id: "openai_whisper-medium", name: "Medium", sizeMB: 1500, description: "High accuracy, slower. Good for CJK languages."),
        .init(id: "openai_whisper-large-v3", name: "Large V3", sizeMB: 3000, description: "Best accuracy, slowest. Best for all languages."),
        .init(id: "openai_whisper-large-v3_turbo", name: "Large V3 Turbo", sizeMB: 1600, description: "Near-best accuracy, much faster than Large V3. Recommended."),
    ]

    // OpenAI API models
    static let openAILLMModels = [
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-4-turbo",
        "gpt-4",
        "gpt-3.5-turbo",
    ]

    // Claude Code CLI models (aliases accepted by `claude --model`)
    static let claudeCodeModels = [
        "sonnet",
        "haiku",
        "opus",
    ]

    // Codex CLI models (accepted by `codex exec -m`, verified with ChatGPT account)
    static let codexModels = [
        "gpt-5.3-codex",
        "gpt-5.2-codex",
        "gpt-5-codex",
        "gpt-5-codex-mini",
    ]
}

// MARK: - Whisper Model Info

struct WhisperModelInfo: Identifiable {
    let id: String
    let name: String
    let sizeMB: Int
    let description: String

    var sizeString: String {
        if sizeMB >= 1000 {
            return String(format: "~%.1f GB", Double(sizeMB) / 1000)
        }
        return "~\(sizeMB) MB"
    }

    var estimatedTotalBytes: Int64 {
        Int64(sizeMB) * 1_000_000
    }
}

// MARK: - Keyboard Shortcuts

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation", default: .init(.d, modifiers: .option))
}

// MARK: - Enums

enum STTProviderType: String, CaseIterable, Identifiable, Codable {
    case whisperKit = "WhisperKit"
    case appleSpeech = "Apple Speech"
    case openAIWhisper = "OpenAI Whisper"

    var id: String { rawValue }
}

enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case claudeCode = "Claude Code CLI"
    case codex = "Codex CLI"
    case claude = "Claude API"
    case openAI = "OpenAI API"
    case localMLX = "Local MLX"

    var id: String { rawValue }
}

enum InjectionMode: String, CaseIterable, Identifiable, Codable {
    case clipboardAndPaste = "Clipboard + Paste"
    case clipboardOnly = "Clipboard Only"

    var id: String { rawValue }
}

// MARK: - CLI Path Resolver

enum CLIResolver {
    /// Search common paths and user's shell PATH for a CLI binary.
    static func findCLI(name: String) -> String {
        let home = NSHomeDirectory()
        let commonPaths = [
            "\(home)/.local/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback: use user's login shell for full PATH resolution
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {}

        return ""
    }
}
