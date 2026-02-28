import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "SenseVoiceModelManager")

// MARK: - SenseVoice Download State

struct SenseVoiceDownloadState {
    var fraction: Double = 0
    let estimatedTotalBytes: Int64
    var isConnecting: Bool = true
    var errorMessage: String?
    var retryCount: Int = 0

    private var lastFraction: Double = 0
    private var lastSpeedUpdateTime: Date = Date()
    var smoothedSpeed: Double = 0

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
        self.errorMessage = nil

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
            smoothedSpeed = 0
            lastSpeedUpdateTime = time
            lastFraction = fraction
        }
    }
}

// MARK: - File Downloader (URLSessionDownloadDelegate)

/// Downloads a file using URLSessionDownloadTask with progress tracking and resume support.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, any Error>?
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private var session: URLSession?

    /// Resume data saved from a failed download, available for retry.
    private(set) var resumeData: Data?

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    func download(from url: URL, existingResumeData: Data? = nil) async throws -> URL {
        resumeData = nil

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600 // 1 hour max per file

            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session

            let task: URLSessionDownloadTask
            if let data = existingResumeData {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: url)
            }
            task.resume()
        }
    }

    func cancel() {
        session?.invalidateAndCancel()
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Must move file before this method returns — URLSession deletes it after
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            continuation?.resume(returning: dest)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        self.session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        guard let error else { return } // Success handled in didFinishDownloadingTo

        // Save resume data for retry
        let nsError = error as NSError
        resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        continuation?.resume(throwing: error)
        continuation = nil
        self.session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}

// MARK: - SenseVoice Model Manager

@Observable
@MainActor
final class SenseVoiceModelManager {
    var downloadedModels: Set<String> = []
    var activeDownloads: [String: SenseVoiceDownloadState] = [:]
    var totalModelSize: String?
    var modelDirectoryPath: String = ""

    private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var activeDownloader: FileDownloader?

    /// SenseVoice models stored in ~/Documents/sherpa-onnx-models/
    private var modelsDir: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("sherpa-onnx-models")
    }

    /// HuggingFace base URL (hf-mirror.com by default for China users)
    private var huggingFaceBaseURL: URL {
        let mirror = UserDefaults.standard.string(forKey: UDKey.huggingFaceMirror)
            ?? Defaults.huggingFaceMirror
        return URL(string: mirror) ?? URL(string: "https://hf-mirror.com")!
    }

    func isModelDownloaded(_ model: String) -> Bool {
        downloadedModels.contains(model)
    }

    func loadAvailableModels() async {
        modelDirectoryPath = modelsDir.path()
        await refreshDownloadedModels()
        updateTotalSize()
    }

    // MARK: - Download

    func startDownload(_ modelID: String) {
        guard activeDownloads[modelID] == nil else { return }
        guard let info = Defaults.senseVoiceModels.first(where: { $0.id == modelID }) else { return }

        activeDownloads[modelID] = SenseVoiceDownloadState(estimatedTotalBytes: info.estimatedTotalBytes)

        let mgr = self
        downloadTasks[modelID] = Task {
            await mgr.performDownload(modelID, info: info)
        }
    }

    func cancelDownload(_ modelID: String) {
        downloadTasks[modelID]?.cancel()
        downloadTasks[modelID] = nil
        activeDownloads[modelID] = nil
        activeDownloader?.cancel()
        activeDownloader = nil
    }

    private func performDownload(_ modelID: String, info: SenseVoiceModelInfo) async {
        logger.info("Starting download of SenseVoice model: \(modelID)")

        do {
            try Task.checkCancellation()

            let modelDir = modelsDir.appendingPathComponent(modelID)
            try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

            let totalFiles = info.requiredFiles.count
            for (index, fileName) in info.requiredFiles.enumerated() {
                try Task.checkCancellation()

                let fileURL = modelDir.appendingPathComponent(fileName)
                guard !FileManager.default.fileExists(atPath: fileURL.path()) else {
                    logger.info("File already exists: \(fileName)")
                    continue
                }

                let downloadURL = huggingFaceBaseURL
                    .appendingPathComponent(info.huggingFaceRepo)
                    .appendingPathComponent("resolve/main")
                    .appendingPathComponent(fileName)

                logger.info("Downloading \(fileName) from \(downloadURL)")

                try await downloadFileWithRetry(
                    url: downloadURL,
                    destination: fileURL,
                    modelID: modelID,
                    fileIndex: index,
                    totalFiles: totalFiles
                )

                logger.info("Downloaded \(fileName)")
            }

            activeDownloads[modelID] = nil
            downloadTasks[modelID] = nil
            activeDownloader = nil
            downloadedModels.insert(modelID)
            logger.info("SenseVoice model download complete: \(modelID)")
        } catch is CancellationError {
            logger.info("Download cancelled for \(modelID)")
            activeDownloads[modelID] = nil
            downloadTasks[modelID] = nil
            activeDownloader = nil
            // Clean up partial download
            let modelDir = modelsDir.appendingPathComponent(modelID)
            try? FileManager.default.removeItem(at: modelDir)
        } catch {
            activeDownloads[modelID]?.errorMessage = error.localizedDescription
            downloadTasks[modelID] = nil
            activeDownloader = nil
            logger.error("Download failed for \(modelID): \(error.localizedDescription)")
        }

        updateTotalSize()
    }

    private func downloadFileWithRetry(
        url: URL,
        destination: URL,
        modelID: String,
        fileIndex: Int,
        totalFiles: Int,
        maxRetries: Int = 3
    ) async throws {
        var lastError: Error?
        var resumeData: Data?

        for attempt in 0..<maxRetries {
            try Task.checkCancellation()

            if attempt > 0 {
                let delay = pow(2.0, Double(attempt)) // 2s, 4s
                logger.info("Retry \(attempt)/\(maxRetries - 1) for \(url.lastPathComponent) after \(delay)s delay...")
                await MainActor.run {
                    self.activeDownloads[modelID]?.retryCount = attempt
                    self.activeDownloads[modelID]?.errorMessage = nil
                    self.activeDownloads[modelID]?.isConnecting = true
                }
                try await Task.sleep(for: .seconds(delay))
            }

            let mgr = self
            let downloader = FileDownloader { bytesWritten, totalExpected in
                let fileFraction: Double
                if totalExpected > 0 {
                    fileFraction = Double(bytesWritten) / Double(totalExpected)
                } else {
                    fileFraction = 0
                }
                let overallFraction = (Double(fileIndex) + fileFraction) / Double(totalFiles)
                let now = Date()
                Task { @MainActor in
                    mgr.activeDownloads[modelID]?.updateProgress(fraction: overallFraction, time: now)
                }
            }

            await MainActor.run {
                self.activeDownloader = downloader
            }

            do {
                let tempURL = try await downloader.download(from: url, existingResumeData: resumeData)

                // Move to final destination
                let fm = FileManager.default
                if fm.fileExists(atPath: destination.path()) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tempURL, to: destination)

                return // Success
            } catch {
                lastError = error
                resumeData = downloader.resumeData

                if resumeData != nil {
                    logger.info("Saved resume data for retry")
                }

                logger.warning("Download attempt \(attempt + 1)/\(maxRetries) failed: \(error.localizedDescription)")
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    // MARK: - Import

    func importModel(from sourceURL: URL) throws {
        let modelName = sourceURL.lastPathComponent
        let destDir = modelsDir.appendingPathComponent(modelName)

        // Validate required files exist
        let fm = FileManager.default
        let requiredFiles = ["model.int8.onnx", "tokens.txt"]
        for file in requiredFiles {
            let filePath = sourceURL.appendingPathComponent(file)
            guard fm.fileExists(atPath: filePath.path()) else {
                throw SenseVoiceModelError.missingRequiredFile(file)
            }
        }

        try fm.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: destDir.path()) {
            try fm.removeItem(at: destDir)
        }
        try fm.copyItem(at: sourceURL, to: destDir)

        downloadedModels.insert(modelName)
        updateTotalSize()
        logger.info("Imported SenseVoice model: \(modelName)")
    }

    // MARK: - Delete

    func deleteModel(_ model: String) {
        let modelDir = modelsDir.appendingPathComponent(model)
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: modelDir.path()) {
                try fm.removeItem(at: modelDir)
                logger.info("Deleted SenseVoice model: \(model)")
            }
        } catch {
            logger.error("Failed to delete model \(model): \(error.localizedDescription)")
        }

        downloadedModels.remove(model)
        updateTotalSize()
    }

    func openModelDirectory() {
        let dir = modelsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    // MARK: - Scan

    func refreshDownloadedModels() async {
        let baseDir = modelsDir
        let fm = FileManager.default

        guard fm.fileExists(atPath: baseDir.path()) else { return }

        var found = Set<String>()

        do {
            let contents = try fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey])
            for dir in contents {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

                let dirName = dir.lastPathComponent
                // Validate required files
                let hasModel = fm.fileExists(atPath: dir.appendingPathComponent("model.int8.onnx").path())
                let hasTokens = fm.fileExists(atPath: dir.appendingPathComponent("tokens.txt").path())

                if hasModel && hasTokens {
                    found.insert(dirName)
                }
            }
        } catch {
            logger.error("Failed to scan SenseVoice model directory: \(error.localizedDescription)")
        }

        downloadedModels = found
    }

    private func updateTotalSize() {
        let baseDir = modelsDir
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

// MARK: - Errors

enum SenseVoiceModelError: LocalizedError {
    case missingRequiredFile(String)
    case modelNotDownloaded(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredFile(let file):
            "Missing required file: \(file). SenseVoice models need model.int8.onnx and tokens.txt."
        case .modelNotDownloaded(let model):
            "SenseVoice model '\(model)' is not downloaded. Please download it in Settings \u{2192} Models."
        }
    }
}
