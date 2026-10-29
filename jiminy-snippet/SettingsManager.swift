//
//  SettingsManager.swift
//  jiminy-snippet
//

import Foundation
import ServiceManagement

@Observable @MainActor
final class SettingsManager {
    static let shared = SettingsManager()

    var launchOnSignIn: Bool {
        didSet { applyLaunchOnSignIn() }
    }

    var showCaptureWindowOnStartup: Bool {
        didSet { UserDefaults.standard.set(showCaptureWindowOnStartup, forKey: Keys.showCaptureWindowOnStartup) }
    }

    /// When enabled, the app's own windows stay on screen during capture so
    /// they appear in the screenshot (e.g. to capture the app itself).
    var includeAppWindowsInCaptures: Bool {
        didSet { UserDefaults.standard.set(includeAppWindowsInCaptures, forKey: Keys.includeAppWindowsInCaptures) }
    }

    private init() {
        self.showCaptureWindowOnStartup = UserDefaults.standard.bool(forKey: Keys.showCaptureWindowOnStartup)
        self.includeAppWindowsInCaptures = UserDefaults.standard.bool(forKey: Keys.includeAppWindowsInCaptures)
        self.launchOnSignIn = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchOnSignIn() {
        do {
            if launchOnSignIn {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Revert on failure
            launchOnSignIn = SMAppService.mainApp.status == .enabled
        }
    }

    private enum Keys {
        static let showCaptureWindowOnStartup = "showCaptureWindowOnStartup"
        static let includeAppWindowsInCaptures = "includeAppWindowsInCaptures"
    }
}
