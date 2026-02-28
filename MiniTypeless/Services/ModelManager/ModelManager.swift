import Foundation
import SwiftUI
import WhisperKit
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "ModelManager")

// MARK: - Download State

/// Per-model download state with self-calculated speed (not relying on Progress.throughputKey).
struct DownloadState {
    var fraction: Double = 0
    let estimatedTotalBytes: Int64
    var isConnecting: Bool = true

    // Speed: calculated from actual progress deltas
    private var lastFraction: Double = 0
    private var lastSpeedUpdateTime: Date = Date()
    var smoothedSpeed: Double = 0 // bytes per second

    init(estimatedTotalBytes: Int64) {
        self.estimatedTotalBytes = estimatedTotalBytes
    }

    var downloadedBytes: Int64 {
        Int64(fraction * Double(estimatedTotalBytes))
    }

    var downloadedString: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }

    var totalString: String {
        ByteCountFormatter.string(fromByteCount: estimatedTotalBytes, countStyle: .file)
    }

    var speedString: String? {
        guard smoothedSpeed > 1024 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(smoothedSpeed), countStyle: .file) + "/s"
    }

    mutating func updateProgress(fraction: Double, time: Date) {
        self.fraction = fraction
        self.isConnecting = false

        let timeDelta = time.timeIntervalSince(lastSpeedUpdateTime)
        let fractionDelta = fraction - lastFraction

        if fractionDelta > 0 && timeDelta > 0.5 {
            let instantSpeed = (fractionDelta * Double(estimatedTotalBytes)) / timeDelta
            if smoothedSpeed < 1024 {
                smoothedSpeed = instantSpeed
            } else {
                smoothedSpeed = 0.3 * instantSpeed + 0.7 * smoothedSpeed
            }
            lastFraction = fraction
            lastSpeedUpdateTime = time
        } else if timeDelta > 5.0 {
            // No progress for 5+ seconds → stalled
            smoothedSpeed = 0
            lastSpeedUpdateTime = time
            lastFraction = fraction
        }
    }
}

// MARK: - Model Manager

@Observable
@MainActor
final class ModelManager {
    var downloadedModels: Set<String> = []
    var activeDownloads: [String: DownloadState] = [:]
    var totalModelSize: String?
    var modelDirectoryPath: String = ""

    private var downloadTasks: [String: Task<Void, Never>] = [:]

    /// WhisperKit stores models via HuggingFace Hub in ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/
    private var whisperKitDir: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
    }

    func isModelDownloaded(_ model: String) -> Bool {
        downloadedModels.contains(model)
    }

    func loadAvailableModels() async {
        modelDirectoryPath = whisperKitDir.path()
        await refreshDownloadedModels()
        updateTotalSize()
    }

    // MARK: - Download

    func startDownload(_ modelID: String) {
        guard activeDownloads[modelID] == nil else { return }

        let info = Defaults.whisperModels.first(where: { $0.id == modelID })
        let totalBytes = info?.estimatedTotalBytes ?? 0

        activeDownloads[modelID] = DownloadState(estimatedTotalBytes: totalBytes)

        nonisolated(unsafe) let mgr = self
        downloadTasks[modelID] = Task {
            await mgr.performDownload(modelID)
        }
    }

    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks[modelID] = nil
        activeDownloads[modelID] = nil
    }

    private func performDownload(_ modelID: String) async {
        logger.info("Starting download of \(modelID)")

        do {
            nonisolated(unsafe) let mgr = self
            let folder = try await WhisperKit.download(
                variant: modelID,
                progressCallback: { @Sendable progress in
                    let now = Date()
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        mgr.activeDownloads[modelID]?.updateProgress(fraction: fraction, time: now)
                    }
                }
            )
            logger.info("Downloaded \(modelID) to \(folder)")

            activeDownloads[modelID] = nil
            downloadTasks[modelID] = nil
            downloadedModels.insert(modelID)
        } catch is CancellationError {
            logger.info("Download cancelled for \(modelID)")
        } catch {
            activeDownloads[modelID] = nil
            downloadTasks[modelID] = nil
            logger.error("Download failed for \(modelID): \(error.localizedDescription)")
        }

        updateTotalSize()
    }

    // MARK: - Delete

    func deleteModel(_ model: String) {
        let baseDir = whisperKitDir
        let fm = FileManager.default

        guard fm.fileExists(atPath: baseDir.path()) else { return }

        do {
            let modelDir = baseDir.appendingPathComponent(model)
            if fm.fileExists(atPath: modelDir.path()) {
                try fm.removeItem(at: modelDir)
                logger.info("Deleted model directory \(modelDir.path())")
            }
        } catch {
            logger.error("Failed to delete model \(model): \(error.localizedDescription)")
        }

        downloadedModels.remove(model)
        updateTotalSize()
    }

    func openModelDirectory() {
        let dir = whisperKitDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Scan

    func refreshDownloadedModels() async {
        let baseDir = whisperKitDir
        let fm = FileManager.default

        guard fm.fileExists(atPath: baseDir.path()) else { return }

        var found = Set<String>()
        let knownIDs = Set(Defaults.whisperModels.map(\.id))

        do {
            let contents = try fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey])
            for dir in contents {
                let dirName = dir.lastPathComponent
                guard knownIDs.contains(dirName) else { continue }
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                   !files.isEmpty {
                    found.insert(dirName)
                }
            }
        } catch {
            logger.error("Failed to scan model directory: \(error.localizedDescription)")
        }

        downloadedModels = found
    }

    private func updateTotalSize() {
        let baseDir = whisperKitDir
        let fm = FileManager.default

        guard fm.fileExists(atPath: baseDir.path()) else {
            totalModelSize = "No models downloaded"
            return
        }

        var totalBytes: Int64 = 0

        if let enumerator = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    totalBytes += Int64(fileSize)
                }
            }
        }

        if totalBytes == 0 {
            totalModelSize = "No models downloaded"
        } else {
            totalModelSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        }
    }
}
