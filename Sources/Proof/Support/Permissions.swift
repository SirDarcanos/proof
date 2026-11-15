import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics

enum PermissionState: Equatable {
    case notDetermined, granted, denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }
}

enum Permissions {
    /// True when this app may enumerate and capture screen content.
    static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the system prompt once; the app has to be relaunched after the grant.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// True when this app may control other apps, which posting scroll events needs. With
    /// `prompt`, macOS asks the person to turn Proof on in System Settings if it isn't yet.
    @discardableResult
    static func accessibilityGranted(prompt: Bool = false) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    static func state(for mediaType: AVMediaType) -> PermissionState {
        PermissionState(AVCaptureDevice.authorizationStatus(for: mediaType))
    }

    static func request(_ mediaType: AVMediaType) async -> Bool {
        await AVCaptureDevice.requestAccess(for: mediaType)
    }

    enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case accessibility = "Privacy_Accessibility"
    }

    @MainActor
    static func openSystemSettings(_ pane: SettingsPane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
