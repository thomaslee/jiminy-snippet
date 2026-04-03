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

    func captureFullscreen() {
        // Use miniaturize instead of orderOut so macOS doesn't lose window state
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
            } catch {
                print("Screenshot failed: \(error)")
            }

            restoreWindows(visibleWindows)
        }
    }

    private func restoreWindows(_ windows: [NSWindow]) {
        for window in windows {
            window.setIsVisible(true)
            window.makeKeyAndOrderFront(nil)
        }
        NSApplication.shared.activate()
    }
}
