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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
            Text(title)

            Spacer()

            switch status {
            case .granted:
                statusLabel(systemImage: "checkmark.circle.fill", text: "Granted", color: .green)
            case .denied:
                Button(action: action) {
                    statusLabel(systemImage: "exclamationmark.triangle.fill", text: "Open Settings", color: .orange)
                }
                .buttonStyle(.borderless)
            case .notRequested:
                Button(action: action) {
                    statusLabel(systemImage: "circle.dashed", text: "Grant", color: .accentColor)
                }
                .buttonStyle(.borderless)
            case .unknown:
                statusLabel(systemImage: "questionmark.circle", text: "Unknown", color: .secondary)
            }
        }
    }

    private func statusLabel(systemImage: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }
}
