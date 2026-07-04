//
//  CaptureService.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// A capture action requested from outside ContentView (e.g. the menu bar
/// item). ContentView watches `CaptureService.pendingCaptureRequest` and
/// dispatches these through its own capture pipeline so the unsaved-changes
/// confirmation and annotation clearing stay in one place regardless of
/// where the request originated.
enum CaptureRequest: Equatable {
    case fullscreen
    case region
    case timed(seconds: Int)
    case fromClipboard
}

/// A capture attempt that failed for a reason worth telling the user about.
/// User cancellations (Escape during region selection or the countdown) are
/// not errors — capture methods return nil for those instead.
struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Drives every way of acquiring a screenshot: fullscreen, region selection,
/// and timed region capture with its countdown UI. Owns the transient windows
/// those flows need (selection overlay, region outline, countdown panel) and
/// the hide-the-app-while-capturing dance.
///
/// Capture methods are async: they return the captured image, return nil when
/// the user cancels, and throw `CaptureError` when the capture itself fails.
@Observable
@MainActor
final class CaptureService {
    /// Out-of-band capture request, set by the menu bar item and consumed by
    /// ContentView. This stays an observable field (rather than an async
    /// call) because the request has to survive the main window being opened:
    /// the menu bar sets it before the window exists, and ContentView
    /// consumes it on first appearance.
    var pendingCaptureRequest: CaptureRequest?

    // MARK: - Timed capture state
    //
    // Implementation details of `captureRegionAfterDelay` — no view observes
    // them, so exclude them from observation tracking.

    @ObservationIgnored private var countdownWindow: NSPanel?
    @ObservationIgnored private var countdownState: CountdownState?
    @ObservationIgnored private var countdownTask: Task<Bool, Never>?
    /// Click-through overlay that outlines the pre-selected region while the
    /// countdown is running, so the user can see what's about to be captured.
    @ObservationIgnored private var regionOutlineWindow: NSWindow?
    /// App windows hidden at the start of a timed capture so they don't clutter
    /// the user's setup. Restored on cancel or after the capture completes.
    @ObservationIgnored private var timedCaptureHiddenWindows: [NSWindow] = []

    // MARK: - Capture Flows

    /// Captures the whole main display. Hides the app's own windows first so
    /// they don't appear in the shot.
    func captureFullscreen() async throws -> NSImage? {
        let hidden = hideAppWindows()
        defer { restoreWindows(hidden) }

        // Give the windows a beat to leave the compositor before capturing.
        try? await Task.sleep(for: .milliseconds(500))
        return try await performFullscreenCapture()
    }

    /// Shows the region-selection overlay and captures the selected region.
    /// Returns nil when the user cancels the selection.
    func captureRegion() async throws -> NSImage? {
        let hidden = hideAppWindows()
        defer { restoreWindows(hidden) }

        guard let screen = NSScreen.main else { return nil }
        guard let selectedRect = await selectRegion(on: screen) else { return nil }
        return try await performRegionCapture(screen: screen, selectedRect: selectedRect)
    }

    /// Shows the region-selection overlay, waits for the user to drag out a
    /// selection, then runs a countdown (with a live outline of the region and
    /// a per-second beep) before capturing. Starting a new timed capture
    /// cancels any in-flight one. Returns nil when the user cancels either
    /// the selection or the countdown.
    func captureRegionAfterDelay(seconds: Int) async throws -> NSImage? {
        cancelTimedCapture()

        // Hide app windows so they're not in the user's way while they're
        // selecting a region or setting up the scene during the countdown.
        // Tracked in a property (not locally) so `cancelTimedCapture` can
        // restore them from the countdown's Escape handler.
        timedCaptureHiddenWindows = hideAppWindows()

        guard let screen = NSScreen.main else {
            cancelTimedCapture()
            return nil
        }
        guard let selectedRect = await selectRegion(on: screen) else {
            // User cancelled the region selection — unwind everything.
            cancelTimedCapture()
            return nil
        }
        guard await runCountdown(seconds: seconds, screen: screen, selectedRect: selectedRect) else {
            // Cancelled mid-countdown — cancelTimedCapture already unwound.
            return nil
        }

        hideCountdownWindow()
        hideRegionOutlineWindow()
        countdownTask = nil

        let hiddenWindows = timedCaptureHiddenWindows
        timedCaptureHiddenWindows = []
        defer { restoreWindows(hiddenWindows) }

        // Give the compositor a beat to drop the outline + countdown panel
        // before snapshotting, otherwise they can leak into the capture on
        // slower machines.
        try? await Task.sleep(for: .milliseconds(200))
        return try await performRegionCapture(screen: screen, selectedRect: selectedRect)
    }

    /// Cancels an in-flight timed capture, restoring any windows that were
    /// hidden when the flow started. Safe to call when no timed capture is
    /// active.
    func cancelTimedCapture() {
        countdownTask?.cancel()
        countdownTask = nil
        hideCountdownWindow()
        hideRegionOutlineWindow()
        if !timedCaptureHiddenWindows.isEmpty {
            let windowsToRestore = timedCaptureHiddenWindows
            timedCaptureHiddenWindows = []
            restoreWindows(windowsToRestore)
        }
    }

    // MARK: - Region Selection

    /// Presents the fullscreen selection overlay and suspends until the user
    /// drags out a region, or returns nil when they cancel with Escape.
    private func selectRegion(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { continuation in
            let selectionWindow = RegionSelectionWindow(screen: screen) { selectedRect in
                continuation.resume(returning: selectedRect)
            }
            selectionWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Countdown

    /// Shows the region outline + countdown panel and ticks down once per
    /// second. Returns true when the countdown ran to completion, false when
    /// it was cancelled via `cancelTimedCapture`.
    private func runCountdown(
        seconds: Int,
        screen: NSScreen,
        selectedRect: CGRect
    ) async -> Bool {
        let outline = RegionOutlineWindow(screen: screen, rect: selectedRect)
        outline.orderFrontRegardless()
        regionOutlineWindow = outline

        let state = CountdownState(seconds: seconds)
        countdownState = state
        let panel = makeCountdownPanel(state: state) { [weak self] in
            self?.cancelTimedCapture()
        }
        let origin = countdownPanelOrigin(
            for: selectedRect,
            screen: screen,
            panelSize: panel.frame.size
        )
        panel.setFrameOrigin(origin)
        countdownWindow = panel
        panel.orderFrontRegardless()
        // Activate the app and make the panel key so it receives the Escape
        // key while the countdown is running. The selection window was just
        // dismissed, so without this our app may lose focus to whatever was
        // frontmost before, and key events would bypass us.
        NSApplication.shared.activate()
        panel.makeKey()

        let task = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                state.seconds = remaining
                // Per-second beep, fired in the same tick the number updates
                // so the audio and visual stay in lockstep.
                NSSound.beep()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return false
                }
                remaining -= 1
            }
            return true
        }
        countdownTask = task
        return await task.value
    }

    private func hideCountdownWindow() {
        countdownWindow?.orderOut(nil)
        countdownWindow = nil
        countdownState = nil
    }

    private func hideRegionOutlineWindow() {
        regionOutlineWindow?.orderOut(nil)
        regionOutlineWindow = nil
    }

    private func makeCountdownPanel(
        state: CountdownState,
        onCancel: @escaping () -> Void
    ) -> NSPanel {
        let size = CGSize(width: 180, height: 180)
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )

        let panel = CountdownPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.onCancel = onCancel
        panel.contentView = NSHostingView(
            rootView: CountdownView(state: state)
        )
        return panel
    }

    /// Picks a screen-space origin for the countdown panel that sits adjacent
    /// to the selected region rather than on top of it, so the user can see
    /// what they're about to capture. Prefers above the selection, falls back
    /// to below, and finally centers on-screen if neither fits.
    private func countdownPanelOrigin(
        for selection: CGRect,
        screen: NSScreen,
        panelSize: CGSize
    ) -> CGPoint {
        let screenFrame = screen.visibleFrame
        let margin: CGFloat = 20

        // `selection` is in bottom-left origin screen coordinates, so
        // `selection.maxY` is the *top* edge of the selection.
        let aboveY = selection.maxY + margin
        if aboveY + panelSize.height <= screenFrame.maxY {
            return clampedPanelOrigin(
                centerX: selection.midX, y: aboveY,
                panelSize: panelSize, screenFrame: screenFrame, margin: margin
            )
        }

        let belowY = selection.minY - panelSize.height - margin
        if belowY >= screenFrame.minY {
            return clampedPanelOrigin(
                centerX: selection.midX, y: belowY,
                panelSize: panelSize, screenFrame: screenFrame, margin: margin
            )
        }

        // Fall back to center of screen (accept overlap).
        return CGPoint(
            x: screenFrame.midX - panelSize.width / 2,
            y: screenFrame.midY - panelSize.height / 2
        )
    }

    private func clampedPanelOrigin(
        centerX: CGFloat, y: CGFloat,
        panelSize: CGSize, screenFrame: CGRect, margin: CGFloat
    ) -> CGPoint {
        let minX = screenFrame.minX + margin
        let maxX = screenFrame.maxX - panelSize.width - margin
        let rawX = centerX - panelSize.width / 2
        return CGPoint(x: max(minX, min(maxX, rawX)), y: y)
    }

    // MARK: - Capture Steps

    private func performFullscreenCapture() async throws -> NSImage {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw CaptureError(message: "No display available to capture.")
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

            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: display.width, height: display.height)
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError(message: error.localizedDescription)
        }
    }

    private func performRegionCapture(
        screen: NSScreen,
        selectedRect: CGRect
    ) async throws -> NSImage {
        // Convert from view coordinates (origin bottom-left) to display points.
        // selectedRect is in the screen's coordinate space (bottom-left origin).
        // SCStreamConfiguration.sourceRect uses top-left origin in points.
        let screenFrame = screen.frame
        let backingScale = screen.backingScaleFactor
        let sourceRect = CGRect(
            x: selectedRect.origin.x - screenFrame.origin.x,
            y: screenFrame.height - selectedRect.origin.y + screenFrame.origin.y - selectedRect.height,
            width: selectedRect.width,
            height: selectedRect.height
        )

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw CaptureError(message: "No display available to capture.")
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

            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: selectedRect.width, height: selectedRect.height)
            )
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError(message: error.localizedDescription)
        }
    }

    // MARK: - Window Hiding

    /// Hides every visible app window and returns them so the caller can
    /// restore exactly that set once the capture flow finishes.
    private func hideAppWindows() -> [NSWindow] {
        let visibleWindows = NSApplication.shared.windows.filter { $0.isVisible }
        for window in visibleWindows {
            window.setIsVisible(false)
        }
        return visibleWindows
    }

    private func restoreWindows(_ windows: [NSWindow]) {
        guard !windows.isEmpty else { return }
        for window in windows {
            window.setIsVisible(true)
            if window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }
        }
        NSApplication.shared.activate()
    }
}

// MARK: - Timed capture countdown UI

/// Mutable state backing the floating countdown panel. A tiny `@Observable`
/// lets the SwiftUI `CountdownView` re-render every tick without rebuilding
/// the hosting view.
@Observable
@MainActor
fileprivate final class CountdownState {
    var seconds: Int
    init(seconds: Int) { self.seconds = seconds }
}

/// Custom panel subclass so the countdown surface can become key and route
/// the Escape key to the cancel callback. A plain `NSPanel` ignores key
/// events, so `keyDown` would never fire.
fileprivate final class CountdownPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 is the keyCode for the Escape key.
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

fileprivate struct CountdownView: View {
    let state: CountdownState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                }
            VStack(spacing: 6) {
                Text("\(state.seconds)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: state.seconds)
                Text("Press Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
