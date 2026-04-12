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

    private init() {
        self.showCaptureWindowOnStartup = UserDefaults.standard.bool(forKey: Keys.showCaptureWindowOnStartup)
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
    }
}
