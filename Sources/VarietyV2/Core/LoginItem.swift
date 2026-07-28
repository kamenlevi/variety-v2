import Foundation
import ServiceManagement

/// Start-at-login registration.
///
/// `SMAppService.mainApp` only works for a real bundle in a normal location —
/// registering from a bare SwiftPM binary, or from a `.app` still sitting in a
/// build directory, fails. `isAvailable` reflects that so the Settings toggle
/// can explain itself instead of silently doing nothing.
enum LoginItem {

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the desired state was reached, so the UI can reflect
    /// reality rather than intent — macOS can refuse, notably when the user has
    /// previously disabled the item in System Settings.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("VarietyV2: login item \(enabled ? "registration" : "removal") failed: \(error)")
            return false
        }
    }

    /// Brings the app's own entry up in System Settings, for when macOS has
    /// blocked the change and the user has to approve it there.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
