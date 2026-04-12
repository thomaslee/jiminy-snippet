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
        // Singleton editor window. `.defaultLaunchBehavior(.suppressed)`
        // keeps it closed at launch so Jiminy lives silently in the menu bar
        // until the user explicitly wants to see it.
        Window("Jiminy Snippet", id: Self.mainWindowID) {
            ContentView()
                .environment(screenshotManager)
                .onAppear { appDelegate.screenshotManager = screenshotManager }
        }
        .defaultSize(width: 900, height: 700)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .saveItem) {
                SaveSceneMenuItem()
                SaveAsSceneMenuItem()
            }
            CommandGroup(replacing: .undoRedo) {
                UndoSceneMenuItem()
                RedoSceneMenuItem()
            }
            CommandGroup(replacing: .pasteboard) {
                CopySceneMenuItem()
                PasteSceneMenuItem()
                Divider()
                DuplicateSceneMenuItem()
            }
            CommandGroup(before: .toolbar) {
                ZoomMenuItems()
                Divider()
            }
        }

        MenuBarExtra {
            MenuBarCommands(mainWindowID: Self.mainWindowID)
                .environment(screenshotManager)
        } label: {
            Image(systemName: "camera")
        }
    }

    static let mainWindowID = "main"
}

/// Menu bar item content. Routes capture commands through
/// `ScreenshotManager.pendingCaptureRequest`, opens the main editor window,
/// and activates the app so the result is immediately visible.
private struct MenuBarCommands: View {
    let mainWindowID: String

    @Environment(ScreenshotManager.self) private var screenshotManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu("Capture") {
            Button("Whole screen") {
                request(.fullscreen)
            }
            Button("Screen region...") {
                request(.region)
            }
            Menu("Screen region with delay...") {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    Button("\(seconds) Seconds") {
                        request(.timed(seconds: seconds))
                    }
                }
            }
            Button("Clipboard") {
                request(.fromClipboard)
            }
        }
        Divider()
        Button("Show Capture Window") {
            showMainWindow()
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// Sets the pending request *before* opening the window so ContentView's
    /// `.task` handler picks it up during its first appearance — otherwise
    /// the value would race the view's initial mount.
    private func request(_ capture: CaptureRequest) {
        screenshotManager.pendingCaptureRequest = capture
        showMainWindow()
    }

    private func showMainWindow() {
        openWindow(id: mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
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

private struct RedoSceneMenuItem: View {
    @FocusedValue(\.redoScene) private var redoScene

    var body: some View {
        Button("Redo") {
            redoScene?()
        }
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .disabled(redoScene == nil)
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

private struct DuplicateSceneMenuItem: View {
    @FocusedValue(\.duplicateScene) private var duplicateScene

    var body: some View {
        Button("Duplicate") {
            duplicateScene?()
        }
        .keyboardShortcut("d", modifiers: .command)
        .disabled(duplicateScene == nil)
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

struct DuplicateSceneActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct RedoSceneActionKey: FocusedValueKey {
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

    var duplicateScene: (() -> Void)? {
        get { self[DuplicateSceneActionKey.self] }
        set { self[DuplicateSceneActionKey.self] = newValue }
    }

    var redoScene: (() -> Void)? {
        get { self[RedoSceneActionKey.self] }
        set { self[RedoSceneActionKey.self] = newValue }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var screenshotManager: ScreenshotManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-first experience: no Dock icon, no auto-raised window at
        // launch. The user brings the editor window up explicitly via the
        // menu bar item (Show Capture Window, or any of the capture commands).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the editor window must not quit the app — Jiminy has to
        // stay alive in the menu bar so the user can capture again.
        false
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
}
