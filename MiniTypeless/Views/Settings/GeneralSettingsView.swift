import SwiftUI
import KeyboardShortcuts

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionManager.self) private var permissions

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Hotkey") {
                KeyboardShortcuts.Recorder("Toggle Dictation", name: .toggleDictation)
                Text("Press once to start recording, press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text Injection") {
                Picker("Mode", selection: $state.injectionMode) {
                    ForEach(InjectionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                if state.injectionMode == .clipboardAndPaste {
                    Text("Requires Accessibility permission to simulate Cmd+V.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                // Microphone
                PermissionRow(
                    title: "Microphone",
                    icon: "mic.fill",
                    status: permissions.microphoneStatus,
                    action: {
                        if permissions.microphoneStatus == .notRequested {
                            Task { await permissions.requestMicrophone() }
                        } else {
                            permissions.openMicrophoneSettings()
                        }
                    }
                )

                // Accessibility
                PermissionRow(
                    title: "Accessibility",
                    icon: "accessibility",
                    status: permissions.accessibilityStatus,
                    action: {
                        if permissions.accessibilityStatus != .granted {
                            permissions.promptAccessibility()
                        }
                    }
                )

                Button("Refresh Status") {
                    permissions.refresh()
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { permissions.refresh() }
    }
}

// MARK: - Permission Row

private struct PermissionRow: View {
    let title: String
    let icon: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 20)
            Text(title)

            Spacer()

            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .denied:
                Button("Open Settings") { action() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
            case .notRequested:
                Button("Grant") { action() }
                    .buttonStyle(.borderless)
            case .unknown:
                Text("Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
