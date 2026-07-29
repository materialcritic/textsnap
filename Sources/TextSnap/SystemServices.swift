import AppKit
import ApplicationServices
import ServiceManagement

@MainActor
enum SystemServices {

    // MARK: Screen Recording

    static func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt. macOS only shows it once per app version, so we
    /// follow up with our own alert pointing at the right settings pane.
    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    static func presentScreenRecordingAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "TextSnap needs Screen Recording access"
        alert.informativeText = """
        Reading text off the screen requires the Screen Recording permission.

        Open Privacy & Security, turn on TextSnap under Screen & System Audio \
        Recording, then quit and reopen TextSnap.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        open(settingsPane: "Privacy_ScreenCapture")
    }

    // MARK: Accessibility (only needed for clear-additive-on-paste)

    static func hasAccessibilityAccess() -> Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        open(settingsPane: "Privacy_Accessibility")
    }

    private static func open(settingsPane pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Login item

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("TextSnap: could not update the login item: \(error.localizedDescription)")
        }
    }
}
