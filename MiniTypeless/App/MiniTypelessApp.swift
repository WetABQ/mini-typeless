import SwiftUI

@main
struct MiniTypelessApp: App {
    @State private var appState = AppState()
    @State private var permissionManager = PermissionManager()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra("MiniTypeless", systemImage: menuBarIcon) {
            MenuBarView()
                .environment(appState)
                .environment(permissionManager)
                .environment(coordinator)
                .task {
                    permissionManager.refresh()
                    coordinator.setup(appState: appState, permissionManager: permissionManager)
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
                .environment(permissionManager)
        }
    }

    private var menuBarIcon: String {
        switch appState.dictationState {
        case .recording: "mic.fill"
        case .loadingModel, .transcribing, .processing: "ellipsis.circle"
        case .injecting: "doc.on.clipboard"
        case .error: "exclamationmark.triangle"
        case .idle: "mic"
        }
    }
}

/// Coordinator: wires hotkey toggle → pipeline, with permission pre-checks.
@MainActor
@Observable
final class AppCoordinator {
    private var pipeline: DictationPipeline?
    private var hotkeyManager: HotkeyManager?
    private weak var permissionManager: PermissionManager?

    func setup(appState: AppState, permissionManager: PermissionManager) {
        guard pipeline == nil else { return }

        self.permissionManager = permissionManager
        let hk = HotkeyManager()
        let p = DictationPipeline(appState: appState)
        pipeline = p
        hotkeyManager = hk

        // Pre-warm audio + preload STT model for instant first recording
        p.warmUp()

        // Configure recording overlay
        let overlay = RecordingOverlayPanel.shared
        overlay.configure(appState: appState)
        overlay.onCancel = { [weak self] in
            self?.cancelPipeline()
        }
        overlay.onConfirm = { [weak p] in
            Task { @MainActor in
                await p?.stopDictation()
            }
        }

        // Auto-hide overlay when pipeline completes
        observeStateForOverlay(appState: appState)

        hk.onToggle = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.handleToggle(pipeline: p, appState: appState)
            }
        }
    }

    func cancelPipeline() {
        pipeline?.cancelPipeline()
        RecordingOverlayPanel.shared.hide()
    }

    private func handleToggle(pipeline: DictationPipeline, appState: AppState) async {
        // Refresh permissions on each toggle
        permissionManager?.refresh()

        if appState.dictationState == .recording {
            // Stop recording — overlay stays visible to show pipeline progress
            await pipeline.stopDictation()
        } else if appState.dictationState == .idle {
            // Pre-flight permission checks
            guard let pm = permissionManager else { return }

            if pm.microphoneStatus == .notRequested {
                let granted = await pm.requestMicrophone()
                if !granted {
                    appState.dictationState = .error("Microphone permission denied")
                    return
                }
            } else if pm.microphoneStatus == .denied {
                appState.dictationState = .error("Microphone permission denied. Open System Settings.")
                pm.openMicrophoneSettings()
                return
            }

            // Start recording
            RecordingOverlayPanel.shared.show()
            await pipeline.startDictation()
        }
    }

    private func observeStateForOverlay(appState: AppState) {
        withObservationTracking {
            _ = appState.dictationState
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if appState.dictationState == .idle {
                    RecordingOverlayPanel.shared.hide()
                }
                self.observeStateForOverlay(appState: appState)
            }
        }
    }
}
