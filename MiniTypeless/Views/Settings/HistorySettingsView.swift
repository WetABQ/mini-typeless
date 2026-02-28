import SwiftUI
import AVFoundation
import os

struct HistorySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""

    private var filtered: [DictationRecord] {
        if searchText.isEmpty { return appState.history }
        return appState.history.filter {
            $0.rawText.localizedCaseInsensitiveContains(searchText) ||
            ($0.processedText?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Text("\(appState.history.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Clear All") {
                    appState.clearHistory()
                }
                .disabled(appState.history.isEmpty)
            }
            .padding(10)

            Divider()

            // List
            if filtered.isEmpty {
                Spacer()
                Text(appState.history.isEmpty ? "No history yet" : "No matches")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { record in
                    HistoryRow(record: record)
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let record: DictationRecord
    @State private var isExpanded = false
    @State private var playerController = AudioPlayerController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header - buttons here must not be swallowed by tap gesture
            HStack {
                Text(record.date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(record.sttProvider)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                if let llm = record.llmProvider {
                    Text(llm)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                if record.errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }

                if let dur = record.durationSeconds {
                    Text(String(format: "%.1fs", dur))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Play audio button
                if record.audioFileName != nil {
                    Button {
                        playerController.toggle(url: record.audioFileURL)
                    } label: {
                        Image(systemName: playerController.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(playerController.isPlaying ? "Stop" : "Play audio")
                }

                Button {
                    let text = record.processedText ?? record.rawText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }

            // Text - tappable for expand/collapse
            VStack(alignment: .leading, spacing: 4) {
                Text(record.processedText ?? record.rawText)
                    .font(.body)
                    .lineLimit(isExpanded ? nil : 2)
                    .textSelection(.enabled)

                if record.processedText != nil && isExpanded {
                    Text("Raw: \(record.rawText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let error = record.errorMessage {
                    Text("Error: \(error)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
        }
        .padding(.vertical, 2)
        .onDisappear { playerController.stop() }
    }
}

// MARK: - Audio Player Controller

private let playerLogger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "AudioPlayer")

/// Class-based controller for audio playback.
/// Avoids NSObject to prevent @Observable + KVO conflicts.
/// Uses a polling Task to detect playback end instead of AVAudioPlayerDelegate.
@Observable
@MainActor
private final class AudioPlayerController {
    var isPlaying = false
    private var player: AVAudioPlayer?
    private var pollTask: Task<Void, Never>?

    func toggle(url: URL?) {
        if isPlaying {
            stop()
        } else {
            play(url: url)
        }
    }

    func play(url: URL?) {
        stop()

        guard let url else {
            playerLogger.warning("play: url is nil")
            return
        }

        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            playerLogger.warning("play: file not found at \(path)")
            return
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            guard p.play() else {
                playerLogger.error("play: AVAudioPlayer.play() returned false")
                return
            }
            player = p
            isPlaying = true
            playerLogger.info("play: started, duration=\(String(format: "%.1f", p.duration))s")

            // Poll for playback end
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard let self, let currentPlayer = self.player else { break }
                    if !currentPlayer.isPlaying {
                        self.isPlaying = false
                        self.player = nil
                        playerLogger.info("play: finished")
                        break
                    }
                }
            }
        } catch {
            playerLogger.error("play: AVAudioPlayer init failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}
