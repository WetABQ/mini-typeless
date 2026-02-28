import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            // Pipeline progress
            HStack {
                PipelineProgressView(
                    state: appState.dictationState,
                    sttProvider: appState.sttProviderType,
                    llmEnabled: appState.llmEnabled
                )

                if appState.dictationState.isActive {
                    Button {
                        coordinator.cancelPipeline()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                }
            }
            .padding(.horizontal)

            Divider()

            // Last result
            if !appState.lastProcessedText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last Result")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.lastProcessedText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                    }
                    Text(appState.lastProcessedText)
                        .font(.body)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                Divider()
            }

            // Shortcut + actions
            HStack {
                Text("Option+D to toggle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings...") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .frame(width: 320)
    }
}

// MARK: - Pipeline Step Definition

/// A single step in the dictation pipeline.
private struct PipelineStep: Identifiable {
    let id: Int
    let icon: String
    let label: String
}

/// Build the correct pipeline steps based on provider type and LLM config.
private func pipelineSteps(sttProvider: STTProviderType, llmEnabled: Bool) -> [PipelineStep] {
    var steps: [PipelineStep] = []
    var idx = 0

    // Step 0: Record (always)
    steps.append(PipelineStep(id: idx, icon: "mic.fill", label: "Record"))
    idx += 1

    // Step 1: Provider-specific middle step
    switch sttProvider {
    case .whisperKit, .senseVoice:
        // Local model needs loading
        steps.append(PipelineStep(id: idx, icon: "arrow.down.circle", label: "Load"))
        idx += 1
    case .openAIWhisper:
        // API needs upload
        steps.append(PipelineStep(id: idx, icon: "arrow.up.circle", label: "Upload"))
        idx += 1
    case .appleSpeech:
        // No extra step — directly transcribes
        break
    }

    // Transcribe
    steps.append(PipelineStep(id: idx, icon: "waveform", label: "Transcribe"))
    idx += 1

    // Optional LLM polish
    if llmEnabled {
        steps.append(PipelineStep(id: idx, icon: "brain", label: "Polish"))
        idx += 1
    }

    // Inject
    steps.append(PipelineStep(id: idx, icon: "doc.on.clipboard", label: "Inject"))

    return steps
}

/// Map DictationState → active step index for given provider.
private func activeStepIndex(state: DictationState, sttProvider: STTProviderType, llmEnabled: Bool) -> Int? {
    switch state {
    case .idle, .error:
        return nil

    case .recording:
        return 0

    case .loadingModel:
        // Only WhisperKit has a "Load" step at index 1.
        // For others, this state shouldn't happen, but map to transcribing step.
        switch sttProvider {
        case .whisperKit, .senseVoice: return 1
        case .openAIWhisper: return 1 // "Upload" step
        case .appleSpeech: return 1   // Transcribe step (no load)
        }

    case .transcribing:
        switch sttProvider {
        case .whisperKit, .senseVoice: return 2
        case .openAIWhisper: return 2
        case .appleSpeech: return 1 // No load step, so transcribe is at 1
        }

    case .processing:
        let base: Int
        switch sttProvider {
        case .whisperKit, .senseVoice, .openAIWhisper: base = 3
        case .appleSpeech: base = 2
        }
        return llmEnabled ? base : nil

    case .injecting:
        let base: Int
        switch sttProvider {
        case .whisperKit, .senseVoice, .openAIWhisper: base = llmEnabled ? 4 : 3
        case .appleSpeech: base = llmEnabled ? 3 : 2
        }
        return base
    }
}

// MARK: - Pipeline Progress View

struct PipelineProgressView: View {
    let state: DictationState
    let sttProvider: STTProviderType
    let llmEnabled: Bool

    private var steps: [PipelineStep] {
        pipelineSteps(sttProvider: sttProvider, llmEnabled: llmEnabled)
    }

    private var activeIndex: Int? {
        activeStepIndex(state: state, sttProvider: sttProvider, llmEnabled: llmEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status text
            HStack(spacing: 6) {
                if state == .idle {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Ready")
                        .font(.headline)
                } else if case .error(let msg) = state {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(state.statusText)
                        .font(.headline)
                }
                Spacer()
            }

            // Step indicators — only shown when pipeline is active
            if state.isActive {
                HStack(spacing: 0) {
                    ForEach(steps) { step in
                        let isActive = step.id == activeIndex
                        let isDone = activeIndex.map { step.id < $0 } ?? false

                        // Each step: icon on top, label below, connected by lines
                        VStack(spacing: 2) {
                            ZStack {
                                if isActive {
                                    Circle()
                                        .fill(.blue)
                                        .frame(width: 22, height: 22)
                                } else if isDone {
                                    Circle()
                                        .fill(.green.opacity(0.15))
                                        .frame(width: 22, height: 22)
                                }

                                Image(systemName: isDone ? "checkmark" : step.icon)
                                    .font(.system(size: 10, weight: isDone ? .bold : .regular))
                                    .foregroundStyle(isActive ? .white : isDone ? .green : .secondary)
                                    .frame(width: 22, height: 22)
                            }

                            Text(step.label)
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)

                        if step.id < steps.last!.id {
                            Rectangle()
                                .fill(isDone ? .green : .secondary.opacity(0.3))
                                .frame(height: 1.5)
                                .frame(maxWidth: 20)
                                .offset(y: -7) // Align with icons, not labels
                        }
                    }
                }
            }
        }
    }
}
