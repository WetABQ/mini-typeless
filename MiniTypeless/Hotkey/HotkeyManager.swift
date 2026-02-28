@preconcurrency import KeyboardShortcuts
import Observation
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "HotkeyManager")

/// Manages global toggle hotkey: press once to start, press again to stop.
@MainActor
@Observable
final class HotkeyManager {
    var onToggle: (() -> Void)?

    init() {
        setupHotkey()
    }

    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            logger.debug("Hotkey toggled")
            self?.onToggle?()
        }
    }
}
