//
//  RegionSelectionWindow.swift
//  jiminy-snippet
//
//  Created by Tom on 4/4/26.
//

import AppKit

/// A fullscreen overlay window that lets the user drag to select a screen region.
/// Returns the selected rectangle in screen coordinates via the completion handler.
final class RegionSelectionWindow: NSWindow {
    private var completion: ((CGRect?) -> Void)?

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        hasShadow = false

        let selectionView = RegionSelectionView { [weak self] rect in
            self?.finish(with: rect)
        }
        selectionView.frame = screen.frame
        contentView = selectionView
    }

    private func finish(with rect: CGRect?) {
        let cb = completion
        completion = nil
        orderOut(nil)
        cb?(rect)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Selection View

private final class RegionSelectionView: NSView {
    private var dragOrigin: CGPoint?
    private var currentRect: CGRect?
    private var onComplete: ((CGRect?) -> Void)?

    init(onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        guard let rect = currentRect else { return }

        // Clear the selected region to show through
        NSGraphicsContext.current?.compositingOperation = .clear
        rect.fill()

        // Draw selection border
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        NSColor.white.setStroke()
        border.stroke()
    }

    // MARK: Mouse Events

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        currentRect = rectFrom(origin, to: current)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let origin = dragOrigin else {
            onComplete?(nil)
            return
        }
        let end = convert(event.locationInWindow, from: nil)
        let rect = rectFrom(origin, to: end)

        // Require a minimum drag size to avoid accidental clicks
        if rect.width < 5 || rect.height < 5 {
            onComplete?(nil)
        } else {
            onComplete?(rect)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels
        if event.keyCode == 53 {
            onComplete?(nil)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Helpers

    private func rectFrom(_ a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
