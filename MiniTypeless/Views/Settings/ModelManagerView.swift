import SwiftUI

struct ModelManagerView: View {
    @Environment(AppState.self) private var appState
    @State private var modelManager = ModelManager()
    @State private var senseVoiceModelManager = SenseVoiceModelManager()
    @State private var showImportPanel = false

    var body: some View {
        Form {
            Section("WhisperKit Models") {
                ForEach(Defaults.whisperModels) { model in
                    whisperModelRow(model)
                }
            }

            Section("SenseVoice Models") {
                ForEach(Defaults.senseVoiceModels) { model in
                    senseVoiceModelRow(model)
                }

                // Scan for manually imported models not in the default list
                let extraModels = senseVoiceModelManager.downloadedModels.filter { id in
                    !Defaults.senseVoiceModels.contains(where: { $0.id == id })
                }
                ForEach(Array(extraModels), id: \.self) { modelId in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(modelId)
                            Text("Imported model")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        importedModelActions(modelId)
                    }
                }

                Button("Import Model Folder...") {
                    importSenseVoiceModel()
                }
                .buttonStyle(.borderless)
            }

            Section("Storage") {
                if let whisperSize = modelManager.totalModelSize {
                    LabeledContent("WhisperKit Models", value: whisperSize)
                }
                if let senseVoiceSize = senseVoiceModelManager.totalModelSize {
                    LabeledContent("SenseVoice Models", value: senseVoiceSize)
                }
                if !modelManager.modelDirectoryPath.isEmpty {
                    LabeledContent("WhisperKit Location") {
                        Text(modelManager.modelDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if !senseVoiceModelManager.modelDirectoryPath.isEmpty {
                    LabeledContent("SenseVoice Location") {
                        Text(senseVoiceModelManager.modelDirectoryPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack {
                    Button("Open WhisperKit Directory") {
                        modelManager.openModelDirectory()
                    }
                    Button("Open SenseVoice Directory") {
                        senseVoiceModelManager.openModelDirectory()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            await modelManager.loadAvailableModels()
            await senseVoiceModelManager.loadAvailableModels()
        }
    }

    // MARK: - WhisperKit Model Row

    @ViewBuilder
    private func whisperModelRow(_ model: WhisperModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if modelManager.downloadedModels.contains(model.id) {
                    whisperDownloadedActions(model)
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

            if let state = modelManager.activeDownloads[model.id] {
                downloadProgressView(fraction: state.fraction, isConnecting: state.isConnecting,
                                    downloadedString: state.downloadedString, totalString: state.totalString,
                                    speedString: state.speedString)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func whisperDownloadedActions(_ model: WhisperModelInfo) -> some View {
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

    // MARK: - SenseVoice Model Row

    @ViewBuilder
    private func senseVoiceModelRow(_ model: SenseVoiceModelInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if senseVoiceModelManager.downloadedModels.contains(model.id) {
                    senseVoiceDownloadedActions(model)
                } else if senseVoiceModelManager.activeDownloads[model.id] != nil {
                    Button {
                        senseVoiceModelManager.cancelDownload(model.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel download")
                } else {
                    Button("Download") {
                        senseVoiceModelManager.startDownload(model.id)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let info = Defaults.senseVoiceModels.first(where: { $0.id == model.id }) {
                Text(info.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let state = senseVoiceModelManager.activeDownloads[model.id] {
                if let error = state.errorMessage {
                    // Download failed — show error and retry button
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") {
                            senseVoiceModelManager.cancelDownload(model.id)
                            senseVoiceModelManager.startDownload(model.id)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    downloadProgressView(
                        fraction: state.fraction,
                        isConnecting: state.isConnecting,
                        downloadedString: state.downloadedString,
                        totalString: state.totalString,
                        speedString: state.speedString,
                        retryCount: state.retryCount
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func senseVoiceDownloadedActions(_ model: SenseVoiceModelInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if model.id == appState.senseVoiceModel {
                Text("Active")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Use") {
                    appState.senseVoiceModel = model.id
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                senseVoiceModelManager.deleteModel(model.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func importedModelActions(_ modelId: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            if modelId == appState.senseVoiceModel {
                Text("Active")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Use") {
                    appState.senseVoiceModel = modelId
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                senseVoiceModelManager.deleteModel(modelId)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Import

    private func importSenseVoiceModel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a SenseVoice model folder containing model.int8.onnx and tokens.txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try senseVoiceModelManager.importModel(from: url)
            } catch {
                // Error is logged in the manager
            }
        }
    }

    // MARK: - Download Progress (shared)

    @ViewBuilder
    private func downloadProgressView(fraction: Double, isConnecting: Bool,
                                      downloadedString: String, totalString: String,
                                      speedString: String?, retryCount: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView(value: max(fraction, 0.001))
                Text("\(Int(fraction * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }

            HStack {
                if isConnecting || fraction < 0.001 {
                    if retryCount > 0 {
                        Text("Reconnecting (retry \(retryCount))...")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(downloadedString) / \(totalString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if let speed = speedString {
                    Text(speed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
