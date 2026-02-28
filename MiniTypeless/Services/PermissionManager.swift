import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import os

private let logger = Logger(subsystem: "com.wetabq.MiniTypeless", category: "PermissionManager")

/// Centralized permission management for microphone and accessibility.
@MainActor
@Observable
final class PermissionManager {

    // MARK: - Observable State

    var microphoneStatus: PermissionStatus = .unknown
    var accessibilityStatus: PermissionStatus = .unknown

    /// Whether all required permissions are granted.
    var allGranted: Bool {
        microphoneStatus == .granted && accessibilityStatus == .granted
    }

    /// Whether we should show the onboarding permission sheet.
    var needsOnboarding: Bool {
        microphoneStatus != .granted || accessibilityStatus != .granted
    }

    // MARK: - Refresh

    /// Poll current system state. Call on app launch and when returning from System Settings.
    func refresh() {
        refreshMicrophone()
        refreshAccessibility()
    }

    // MARK: - Microphone

    func refreshMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .notRequested
        @unknown default:
            microphoneStatus = .unknown
        }
        logger.info("Microphone: \(self.microphoneStatus.rawValue)")
    }

    /// Request microphone access. Returns true if granted.
    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicrophone()
        return granted
    }

    // MARK: - Accessibility

    func refreshAccessibility() {
        if AXIsProcessTrusted() {
            accessibilityStatus = .granted
        } else {
            // We can't distinguish "not requested" from "denied" for accessibility,
            // but if we've prompted before and it's still false, it's effectively denied.
            accessibilityStatus = .denied
        }
        logger.info("Accessibility: \(self.accessibilityStatus.rawValue)")
    }

    /// Prompt the system accessibility dialog. User must toggle the switch in System Settings.
    nonisolated func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings → Privacy → Accessibility directly.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open System Settings → Privacy → Microphone directly.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Permission Status

enum PermissionStatus: String {
    case unknown
    case notRequested = "not_requested"
    case granted
    case denied
}
