import SwiftUI
import AppKit

// MARK: - Recording Overlay Panel (NSPanel)

final class RecordingOverlayPanel: NSPanel {
    static let shared = RecordingOverlayPanel()

    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 52),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    /// Inject AppState and wire callbacks. Call once during app setup.
    func configure(appState: AppState) {
        let content = RecordingOverlayContent(
            onCancel: { [weak self] in self?.onCancel?() },
            onConfirm: { [weak self] in self?.onConfirm?() }
        )
        .environment(appState)

        contentView = NSHostingView(rootView: content)
    }

    func show() {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - frame.width / 2
            let y = screenFrame.maxY - 120
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }
}

// MARK: - Overlay SwiftUI Content

struct RecordingOverlayContent: View {
    @Environment(AppState.self) private var appState

    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        Group {
            switch appState.dictationState {
            case .recording:
                recordingView
            case .loadingModel:
                processingView(text: "Loading model...")
            case .transcribing:
                processingView(text: "Transcribing...")
            case .processing:
                processingView(text: "Polishing...")
            case .injecting:
                processingView(text: "Injecting...")
            case .error(let msg):
                errorView(message: msg)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }

    // MARK: - Recording View (audio bars + buttons)

    private var recordingView: some View {
        HStack(spacing: 12) {
            overlayButton(icon: "xmark", action: onCancel)

            AudioLevelBarsView(levels: appState.audioLevelHistory)
                .frame(height: 28)

            overlayButton(icon: "checkmark", action: onConfirm)
        }
    }

    // MARK: - Processing View (spinner + label)

    private func processingView(text: String) -> some View {
        HStack(spacing: 10) {
            overlayButton(icon: "xmark", action: onCancel)

            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14))

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Button Helper

    private func overlayButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Audio Level Bars

struct AudioLevelBarsView: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<levels.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(for: levels[i]))
                    .animation(.easeOut(duration: 0.08), value: levels[i])
            }
        }
    }

    private func barHeight(for level: Float) -> CGFloat {
        let minH: CGFloat = 4
        let maxH: CGFloat = 28
        return minH + CGFloat(level) * (maxH - minH)
    }
}
