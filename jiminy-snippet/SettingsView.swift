//
//  SettingsView.swift
//  jiminy-snippet
//

import SwiftUI

struct SettingsView: View {
    @Bindable private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Toggle("Launch on sign in", isOn: $settings.launchOnSignIn)
            Toggle("Show capture window on startup", isOn: $settings.showCaptureWindowOnStartup)
        }
        .formStyle(.grouped)
        .frame(width: 350)
        .fixedSize()
    }
}
