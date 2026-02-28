import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "TextInjector")

/// Injects text into the currently focused application via clipboard + simulated Cmd+V.
@MainActor
enum TextInjector {

    /// Injects text using the specified mode.
    static func inject(_ text: String, mode: InjectionMode) async {
        switch mode {
        case .clipboardAndPaste:
            await injectViaPaste(text)
        case .clipboardOnly:
            copyToClipboard(text)
        }
    }

    // MARK: - Private

    private static func injectViaPaste(_ text: String) async {
        let pasteboard = NSPasteboard.general

        // Save current clipboard (first type of each item)
        var savedItems: [(NSPasteboard.PasteboardType, Data)] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                for type in item.types {
                    if let data = item.data(forType: type) {
                        savedItems.append((type, data))
                        break
                    }
                }
            }
        }

        // Set new text
        copyToClipboard(text)

        // Small delay to ensure pasteboard is ready
        try? await Task.sleep(for: .milliseconds(50))

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after a delay
        try? await Task.sleep(for: .milliseconds(200))

        if !savedItems.isEmpty {
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
            logger.debug("Clipboard restored")
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.debug("Text copied to clipboard (\(text.count) chars)")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        logger.debug("Simulated Cmd+V")
    }
}
