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
                .onAppear { appDelegate.screenshotManager = screenshotManager }
        }
        .defaultSize(width: 900, height: 700)
        .commands {
            CommandGroup(replacing: .pasteboard) {
                CopySceneMenuItem()
            }
        }
    }
}

private struct CopySceneMenuItem: View {
    @FocusedValue(\.copyScene) private var copyScene

    var body: some View {
        Button("Copy") {
            copyScene?()
        }
        .keyboardShortcut("c", modifiers: .command)
        .disabled(copyScene == nil)
    }
}

struct CopySceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyScene: (() -> Void)? {
        get { self[CopySceneActionKey.self] }
        set { self[CopySceneActionKey.self] = newValue }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var screenshotManager: ScreenshotManager?

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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = screenshotManager,
              manager.hasUnsavedChanges else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "You have unsaved changes"
        alert.informativeText = "Your screenshot has not been exported since the last edit. Quit anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    private func ensureWindowVisible() {
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
