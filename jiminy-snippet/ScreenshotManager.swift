//
//  ScreenshotManager.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import AppKit
import Observation
import ScreenCaptureKit

@Observable
@MainActor
final class ScreenshotManager {
    var capturedImage: NSImage?
    var hasUnsavedChanges = false
    /// URL of the file backing the current screenshot, if it has been saved.
    /// Reset to `nil` whenever a new image is loaded from a fresh source
    /// (capture, paste) — but preserved through in-place edits like crop and
    /// rotate so that Save can overwrite the existing file.
    var currentFileURL: URL?

    /// Presents a modal warning when there are unsaved changes and returns
    /// whether the caller should proceed with the destructive action.
    static func confirmDiscardUnsavedChanges(
        messageText: String,
        informativeText: String,
        proceedButtonTitle: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: proceedButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func captureFullscreen() {
        let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
        for window in visibleWindows {
            window.setIsVisible(false)
        }

        Task {
            try? await Task.sleep(for: .milliseconds(500))

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    restoreWindows(visibleWindows)
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = display.width * 2
                config.height = display.height * 2
                config.showsCursor = false

                let cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )

                self.capturedImage = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: display.width, height: display.height)
                )
                self.currentFileURL = nil
            } catch {
                print("Screenshot failed: \(error)")
            }

            restoreWindows(visibleWindows)
        }
    }

    func captureRegion() {
        let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
        for window in visibleWindows {
            window.setIsVisible(false)
        }

        guard let screen = NSScreen.main else {
            restoreWindows(visibleWindows)
            return
        }

        let selectionWindow = RegionSelectionWindow(screen: screen) { [weak self] selectedRect in
            guard let self else { return }
            guard let selectedRect else {
                restoreWindows(visibleWindows)
                return
            }

            // Convert from view coordinates (origin bottom-left) to display points
            let screenFrame = screen.frame
            let backingScale = screen.backingScaleFactor

            // selectedRect is in the screen's coordinate space (bottom-left origin).
            // SCStreamConfiguration.sourceRect uses top-left origin in points.
            let sourceRect = CGRect(
                x: selectedRect.origin.x - screenFrame.origin.x,
                y: screenFrame.height - selectedRect.origin.y + screenFrame.origin.y - selectedRect.height,
                width: selectedRect.width,
                height: selectedRect.height
            )

            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(
                        false, onScreenWindowsOnly: true
                    )
                    guard let display = content.displays.first else {
                        self.restoreWindows(visibleWindows)
                        return
                    }

                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.sourceRect = sourceRect
                    config.width = Int(selectedRect.width * backingScale)
                    config.height = Int(selectedRect.height * backingScale)
                    config.showsCursor = false

                    let cgImage = try await SCScreenshotManager.captureImage(
                        contentFilter: filter,
                        configuration: config
                    )

                    self.capturedImage = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: selectedRect.width, height: selectedRect.height)
                    )
                    self.currentFileURL = nil
                } catch {
                    print("Region capture failed: \(error)")
                }

                self.restoreWindows(visibleWindows)
            }
        }

        selectionWindow.makeKeyAndOrderFront(nil)
    }

    private func restoreWindows(_ windows: [NSWindow]) {
        for window in windows {
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
    }
}
