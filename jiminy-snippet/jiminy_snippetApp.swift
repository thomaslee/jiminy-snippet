//
//  jiminy_snippetApp.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

@main
struct jiminy_snippetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var screenshotManager = ScreenshotManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(screenshotManager)
        }
        .defaultSize(width: 900, height: 700)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.ensureWindowVisible()
            NSApplication.shared.activate()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ensureWindowVisible()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureWindowVisible()
        return true
    }

    private func ensureWindowVisible() {
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
