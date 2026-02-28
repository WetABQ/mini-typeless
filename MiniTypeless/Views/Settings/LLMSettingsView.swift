import SwiftUI

struct LLMSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("LLM Processing") {
                Toggle("Enable LLM polishing", isOn: $state.llmEnabled)
            }

            if state.llmEnabled {
                Section("LLM Provider") {
                    Picker("Provider", selection: $state.llmProviderType) {
                        ForEach(LLMProviderType.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                }

                switch state.llmProviderType {
                case .claudeCode:
                    claudeCodeSection(state: $state)
                case .codex:
                    codexSection(state: $state)
                case .claude:
                    claudeSection(state: $state)
                case .openAI:
                    openAISection(state: $state)
                case .localMLX:
                    localMLXSection(state: $state)
                }

                // Temperature/tokens only apply to API providers
                if state.llmProviderType == .claude || state.llmProviderType == .openAI {
                    parametersSection(state: $state)
                }

                Section("System Prompt") {
                    TextEditor(text: $state.llmSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)

                    Button("Reset to Default") {
                        state.llmSystemPrompt = Defaults.llmSystemPrompt
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Claude Code CLI Section

    @ViewBuilder
    private func claudeCodeSection(state: Bindable<AppState>) -> some View {
        Section("Claude Code CLI") {
            HStack {
                TextField("CLI Path", text: state.claudeCodeCliPath)
                    .textFieldStyle(.roundedBorder)
                Button("Detect") {
                    state.wrappedValue.claudeCodeCliPath = CLIResolver.findCLI(name: "claude")
                }
            }
            cliStatusLabel(path: state.wrappedValue.claudeCodeCliPath)

            Picker("Model", selection: state.claudeCodeModel) {
                ForEach(Defaults.claudeCodeModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Text("Uses your logged-in Claude Code session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Codex CLI Section

    @ViewBuilder
    private func codexSection(state: Bindable<AppState>) -> some View {
        Section("Codex CLI") {
            HStack {
                TextField("CLI Path", text: state.codexCliPath)
                    .textFieldStyle(.roundedBorder)
                Button("Detect") {
                    state.wrappedValue.codexCliPath = CLIResolver.findCLI(name: "codex")
                }
            }
            cliStatusLabel(path: state.wrappedValue.codexCliPath)

            Picker("Model", selection: state.codexModel) {
                ForEach(Defaults.codexModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            Text("Uses your logged-in Codex session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - CLI Status Label

    @ViewBuilder
    private func cliStatusLabel(path: String) -> some View {
        if path.isEmpty {
            Label("CLI not found. Click Detect or set path manually.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        } else if !FileManager.default.isExecutableFile(atPath: path) {
            Label("Not found at: \(path)", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        } else {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    // MARK: - Claude Section

    @ViewBuilder
    private func claudeSection(state: Bindable<AppState>) -> some View {
        Section("Claude") {
            APIKeyField(title: "Anthropic API Key", text: state.anthropicAPIKey)

            TextField("Base URL (optional)", text: state.anthropicBaseURL)
                .textFieldStyle(.roundedBorder)

            Picker("Model", selection: state.claudeModel) {
                ForEach(Defaults.claudeModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    // MARK: - OpenAI Section

    @ViewBuilder
    private func openAISection(state: Bindable<AppState>) -> some View {
        Section("OpenAI") {
            APIKeyField(title: "OpenAI API Key", text: state.openAIAPIKey)

            TextField("Base URL (optional)", text: state.openAIBaseURL)
                .textFieldStyle(.roundedBorder)

            Picker("Model", selection: state.openAILLMModel) {
                ForEach(Defaults.openAILLMModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
        }
    }

    // MARK: - Local MLX Section

    @ViewBuilder
    private func localMLXSection(state: Bindable<AppState>) -> some View {
        Section("Local MLX") {
            TextField("Model", text: state.localLLMModel)
                .textFieldStyle(.roundedBorder)
            Text("Default: \(Defaults.localLLMModel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Parameters Section

    @ViewBuilder
    private func parametersSection(state: Bindable<AppState>) -> some View {
        Section("Parameters") {
            HStack {
                Text("Temperature")
                Spacer()
                Text(String(format: "%.1f", state.wrappedValue.llmTemperature))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: state.llmTemperature, in: 0...2, step: 0.1)

            Stepper("Max Tokens: \(state.wrappedValue.llmMaxTokens)",
                    value: state.llmMaxTokens, in: 256...32768, step: 256)

            Button("Reset Parameters") {
                state.wrappedValue.llmTemperature = Defaults.llmTemperature
                state.wrappedValue.llmMaxTokens = Defaults.llmMaxTokens
            }
        }
    }
}
