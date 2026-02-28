import SwiftUI

struct ModelManagerView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = ModelManager()

    var body: some View {
        Form {
            Section("WhisperKit Models") {
                ForEach(Defaults.whisperModels) { model in
                    modelRow(model)
                }
            }

            Section("Storage") {
                if let size = modelManager.totalModelSize {
                    LabeledContent("Total Size", value: size)
                }
                if !modelManager.modelDirectoryPath.isEmpty {
                    LabeledContent("Location") {
                        Text(modelManager.modelDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button("Open Model Directory") {
                    modelManager.openModelDirectory()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await modelManager.loadAvailableModels()
        }
    }

    @ViewBuilder
    private func modelRow(_ model: WhisperModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if modelManager.downloadedModels.contains(model.id) {
                    downloadedActions(model)
                } else if modelManager.activeDownloads[model.id] != nil {
                    Button {
                        modelManager.cancelDownload(model.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel download")
                } else {
                    Button("Download") {
                        modelManager.startDownload(model.id)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Download progress (only when actively downloading)
            if let state = modelManager.activeDownloads[model.id] {
                downloadProgressView(state)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func downloadedActions(_ model: WhisperModelInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if model.id == appState.whisperModel {
                Text("Active")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Use") {
                    appState.whisperModel = model.id
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                modelManager.deleteModel(model.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func downloadProgressView(_ state: DownloadState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Progress bar with single percentage
            HStack {
                ProgressView(value: max(state.fraction, 0.001))
                Text("\(Int(state.fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }

            // Status line: bytes or connecting
            HStack {
                if state.isConnecting || state.fraction < 0.001 {
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(state.downloadedString) / \(state.totalString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let speed = state.speedString {
                    Text(speed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
