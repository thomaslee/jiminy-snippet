//
//  ScreenshotManager.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// A capture action requested from outside ContentView (e.g. the menu bar
/// item). ContentView watches `ScreenshotManager.pendingCaptureRequest` and
/// dispatches these through its existing capture pipeline so the unsaved-
/// changes confirmation, annotation clearing, and capture itself all stay in
/// one place.
enum CaptureRequest: Equatable {
    case fullscreen
    case region
    case timed(seconds: Int)
    case fromClipboard
}

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

    /// Out-of-band capture request, set by the menu bar item and consumed by
    /// ContentView. Using a state field here (instead of calling capture
    /// methods directly from the menu bar) lets ContentView apply its
    /// existing unsaved-changes confirmation and annotation-clearing logic
    /// uniformly across every capture code path.
    var pendingCaptureRequest: CaptureRequest?

    // MARK: - Timed capture state
    //
    // These are implementation details of `captureFullscreenAfterDelay` — no
    // view observes them, so exclude them from observation tracking.

    @ObservationIgnored private var countdownWindow: NSPanel?
    @ObservationIgnored private var countdownState: CountdownState?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    /// Click-through overlay that outlines the pre-selected region while the
    /// countdown is running, so the user can see what's about to be captured.
    @ObservationIgnored private var regionOutlineWindow: NSWindow?
    /// App windows hidden at the start of a timed capture so they don't clutter
    /// the user's setup. Restored on cancel or after the capture completes.
    @ObservationIgnored private var timedCaptureHiddenWindows: [NSWindow] = []

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
            await performFullscreenCapture()
            restoreWindows(visibleWindows)
        }
    }

    /// Actual capture step, shared by `captureFullscreen` and the timed
    /// variant. Assumes the caller has already hidden the app's own windows
    /// and is responsible for restoring them afterwards.
    private func performFullscreenCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { return }

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
    }

    /// Shows the region-selection overlay, waits for the user to drag out a
    /// selection, then runs a countdown (with a live outline of the region and
    /// a per-second beep) before capturing. Starting a new timed capture
    /// cancels any in-flight one.
    func captureRegionAfterDelay(seconds: Int) {
        cancelTimedCapture()

        // Hide app windows so they're not in the user's way while they're
        // selecting a region or setting up the scene during the countdown.
        let toHide = NSApplication.shared.windows.filter { $0.isVisible }
        for window in toHide {
            window.setIsVisible(false)
        }
        timedCaptureHiddenWindows = toHide

        guard let screen = NSScreen.main else {
            cancelTimedCapture()
            return
        }

        let selectionWindow = RegionSelectionWindow(screen: screen) { [weak self] selectedRect in
            guard let self else { return }
            guard let selectedRect else {
                // User cancelled the region selection — unwind everything.
                self.cancelTimedCapture()
                return
            }
            self.beginRegionCountdown(
                screen: screen,
                selectedRect: selectedRect,
                seconds: seconds
            )
        }
        selectionWindow.makeKeyAndOrderFront(nil)
    }

    /// After the user has picked a region, shows the outline + countdown panel
    /// and spins up the ticking task. Called exactly once per timed capture.
    private func beginRegionCountdown(
        screen: NSScreen,
        selectedRect: CGRect,
        seconds: Int
    ) {
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

        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var remaining = seconds
            while remaining > 0 {
                state.seconds = remaining
                // Per-second beep, fired in the same tick the number updates
                // so the audio and visual stay in lockstep.
                NSSound.beep()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                remaining -= 1
            }
            await self.performTimedRegionCapture(
                screen: screen,
                selectedRect: selectedRect
            )
        }
    }

    /// Called when the countdown hits zero. Tears down the outline + countdown
    /// panel, briefly waits for them to clear the compositor, captures, then
    /// restores whatever windows the timed-capture flow originally hid.
    private func performTimedRegionCapture(
        screen: NSScreen,
        selectedRect: CGRect
    ) async {
        hideCountdownWindow()
        hideRegionOutlineWindow()
        countdownTask = nil

        let hiddenWindows = timedCaptureHiddenWindows
        timedCaptureHiddenWindows = []

        // Give the compositor a beat to drop the outline + countdown panel
        // before snapshotting, otherwise they can leak into the capture on
        // slower machines.
        try? await Task.sleep(for: .milliseconds(200))
        await performRegionCapture(screen: screen, selectedRect: selectedRect)
        restoreWindows(hiddenWindows)
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

        let panel = NSPanel(
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
        panel.contentView = NSHostingView(
            rootView: CountdownView(state: state, onCancel: onCancel)
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
                self.restoreWindows(visibleWindows)
                return
            }
            Task {
                await self.performRegionCapture(screen: screen, selectedRect: selectedRect)
                self.restoreWindows(visibleWindows)
            }
        }

        selectionWindow.makeKeyAndOrderFront(nil)
    }

    /// Actual region-capture step, shared by `captureRegion` and the timed
    /// variant. The caller is responsible for hiding/restoring app windows.
    private func performRegionCapture(screen: NSScreen, selectedRect: CGRect) async {
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
            guard let display = content.displays.first else { return }

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

fileprivate struct CountdownView: View {
    let state: CountdownState
    let onCancel: () -> Void

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
                Text("Click to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)
    }
}
