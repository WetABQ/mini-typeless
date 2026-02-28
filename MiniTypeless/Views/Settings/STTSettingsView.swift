import SwiftUI

struct STTSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = ModelManager()
    @State private var isPreloading = false
    @State private var preloadError: String?

    /// Whether the currently selected whisper model is loaded in memory.
    private var isModelCached: Bool {
        appState.cachedWhisperModel == appState.whisperModel
    }

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Speech-to-Text Provider") {
                Picker("Provider", selection: $state.sttProviderType) {
                    ForEach(STTProviderType.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
            }

            Section("Language") {
                Picker("Language", selection: $state.sttLanguage) {
                    ForEach(Defaults.supportedLanguages, id: \.code) { lang in
                        Text("\(lang.name) (\(lang.code))").tag(lang.code)
                    }
                }
            }

            switch state.sttProviderType {
            case .whisperKit:
                whisperKitSection(state: $state)
            case .openAIWhisper:
                openAIWhisperSection(state: $state)
            case .appleSpeech:
                appleSpeechSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await modelManager.loadAvailableModels()
        }
    }

    // MARK: - WhisperKit Section

    @ViewBuilder
    private func whisperKitSection(state: Bindable<AppState>) -> some View {
        Section("WhisperKit Model") {
            Picker("Model", selection: state.whisperModel) {
                ForEach(Defaults.whisperModels) { model in
                    let downloaded = modelManager.isModelDownloaded(model.id)
                    Text("\(model.name) (\(model.sizeString))" + (downloaded ? "" : " - Not Downloaded"))
                        .tag(model.id)
                }
            }

            if !modelManager.isModelDownloaded(state.wrappedValue.whisperModel) {
                Label("Selected model is not downloaded. Please download it in the Models tab.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                if let info = Defaults.whisperModels.first(where: { $0.id == state.wrappedValue.whisperModel }) {
                    Text(info.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Model Cache") {
            HStack {
                if isPreloading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading model into memory...")
                        .foregroundStyle(.secondary)
                } else if isModelCached {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Model loaded and cached")
                        .foregroundStyle(.secondary)
                } else if let error = preloadError {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Button("Preload Model") {
                        Task { await preloadModel() }
                    }
                    .disabled(!modelManager.isModelDownloaded(appState.whisperModel))
                    Text("Load model into memory for faster first dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Decoding Options") {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.1f", state.wrappedValue.whisperTemperature))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: state.whisperTemperature, in: 0...1, step: 0.1)

            Stepper("Fallback Count: \(state.wrappedValue.whisperTemperatureFallbackCount)",
                    value: state.whisperTemperatureFallbackCount, in: 0...10)

            Toggle("Use Prefill Prompt", isOn: state.whisperUsePrefillPrompt)

            HStack {
                Text("Compression Ratio Threshold")
                Spacer()
                Text(String(format: "%.1f", state.wrappedValue.whisperCompressionRatioThreshold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: state.whisperCompressionRatioThreshold, in: 1.0...5.0, step: 0.1)

            HStack {
                Text("No Speech Threshold")
                Spacer()
                Text(String(format: "%.2f", state.wrappedValue.whisperNoSpeechThreshold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: state.whisperNoSpeechThreshold, in: 0.0...1.0, step: 0.05)

            Button("Reset to Defaults") {
                state.wrappedValue.whisperTemperature = Defaults.whisperTemperature
                state.wrappedValue.whisperTemperatureFallbackCount = Defaults.whisperTempFallbackCount
                state.wrappedValue.whisperUsePrefillPrompt = Defaults.whisperUsePrefillPrompt
                state.wrappedValue.whisperCompressionRatioThreshold = Defaults.whisperCompressionRatioThreshold
                state.wrappedValue.whisperNoSpeechThreshold = Defaults.whisperNoSpeechThreshold
            }
        }
    }

    // MARK: - Preload

    private func preloadModel() async {
        isPreloading = true
        preloadError = nil
        do {
            let stt = WhisperKitSTT(modelName: appState.whisperModel)
            try await stt.prepare()
            appState.cachedWhisperModel = appState.whisperModel
        } catch {
            preloadError = error.localizedDescription
        }
        isPreloading = false
    }

    // MARK: - OpenAI Whisper Section

    @ViewBuilder
    private func openAIWhisperSection(state: Bindable<AppState>) -> some View {
        Section("OpenAI Whisper") {
            APIKeyField(title: "OpenAI API Key", text: state.openAIAPIKey)

            TextField("Base URL (optional)", text: state.openAIBaseURL)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Apple Speech Section

    @ViewBuilder
    private var appleSpeechSection: some View {
        Section("Apple Speech") {
            Text("Uses the built-in macOS speech recognizer. No API key needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Make sure to grant microphone and speech recognition permissions in System Settings \u{2192} Privacy & Security.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
