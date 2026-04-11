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
            CommandGroup(replacing: .saveItem) {
                SaveSceneMenuItem()
                SaveAsSceneMenuItem()
            }
            CommandGroup(replacing: .undoRedo) {
                UndoSceneMenuItem()
            }
            CommandGroup(replacing: .pasteboard) {
                CopySceneMenuItem()
                PasteSceneMenuItem()
            }
            CommandGroup(before: .toolbar) {
                ZoomMenuItems()
                Divider()
            }
        }
    }
}

private struct UndoSceneMenuItem: View {
    @FocusedValue(\.undoScene) private var undoScene

    var body: some View {
        Button("Undo") {
            undoScene?()
        }
        .keyboardShortcut("z", modifiers: .command)
        .disabled(undoScene == nil)
    }
}

private struct ZoomMenuItems: View {
    @FocusedValue(\.zoomInScene) private var zoomIn
    @FocusedValue(\.zoomOutScene) private var zoomOut
    @FocusedValue(\.zoomToFitScene) private var zoomToFit
    @FocusedValue(\.zoomActualSizeScene) private var zoomActualSize

    var body: some View {
        Button("Zoom In") {
            zoomIn?()
        }
        .keyboardShortcut("=", modifiers: .command)
        .disabled(zoomIn == nil)

        Button("Zoom Out") {
            zoomOut?()
        }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(zoomOut == nil)

        Button("Zoom to Fit") {
            zoomToFit?()
        }
        .disabled(zoomToFit == nil)

        Button("Zoom to Actual Size") {
            zoomActualSize?()
        }
        .disabled(zoomActualSize == nil)
    }
}

private struct SaveSceneMenuItem: View {
    @FocusedValue(\.saveScene) private var saveScene

    var body: some View {
        Button("Save") {
            saveScene?()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(saveScene == nil)
    }
}

private struct SaveAsSceneMenuItem: View {
    @FocusedValue(\.saveAsScene) private var saveAsScene

    var body: some View {
        Button("Save As...") {
            saveAsScene?()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])
        .disabled(saveAsScene == nil)
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

private struct PasteSceneMenuItem: View {
    @FocusedValue(\.pasteScene) private var pasteScene

    var body: some View {
        Button("Paste") {
            pasteScene?()
        }
        .keyboardShortcut("v", modifiers: .command)
        .disabled(pasteScene == nil)
    }
}

struct CopySceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct PasteSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct SaveSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct SaveAsSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomInSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomOutSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomToFitSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomActualSizeSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct UndoSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyScene: (() -> Void)? {
        get { self[CopySceneActionKey.self] }
        set { self[CopySceneActionKey.self] = newValue }
    }

    var pasteScene: (() -> Void)? {
        get { self[PasteSceneActionKey.self] }
        set { self[PasteSceneActionKey.self] = newValue }
    }

    var saveScene: (() -> Void)? {
        get { self[SaveSceneActionKey.self] }
        set { self[SaveSceneActionKey.self] = newValue }
    }

    var saveAsScene: (() -> Void)? {
        get { self[SaveAsSceneActionKey.self] }
        set { self[SaveAsSceneActionKey.self] = newValue }
    }

    var zoomInScene: (() -> Void)? {
        get { self[ZoomInSceneActionKey.self] }
        set { self[ZoomInSceneActionKey.self] = newValue }
    }

    var zoomOutScene: (() -> Void)? {
        get { self[ZoomOutSceneActionKey.self] }
        set { self[ZoomOutSceneActionKey.self] = newValue }
    }

    var zoomToFitScene: (() -> Void)? {
        get { self[ZoomToFitSceneActionKey.self] }
        set { self[ZoomToFitSceneActionKey.self] = newValue }
    }

    var zoomActualSizeScene: (() -> Void)? {
        get { self[ZoomActualSizeSceneActionKey.self] }
        set { self[ZoomActualSizeSceneActionKey.self] = newValue }
    }

    var undoScene: (() -> Void)? {
        get { self[UndoSceneActionKey.self] }
        set { self[UndoSceneActionKey.self] = newValue }
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

        let proceed = ScreenshotManager.confirmDiscardUnsavedChanges(
            messageText: "You have unsaved changes",
            informativeText: "Your screenshot has not been exported since the last edit. Quit anyway?",
            proceedButtonTitle: "Quit"
        )
        return proceed ? .terminateNow : .terminateCancel
    }

    private func ensureWindowVisible() {
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
