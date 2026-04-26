//
//  DragOutHandle.swift
//  jiminy-snippet
//
//  Provides a drag-out source over the annotation canvas so the rendered
//  image can be dragged into Finder, Slack, Mail, etc. — like Preview's
//  screenshot thumbnail.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot of the canvas state needed to start a drag-out session. Captured
/// up-front so the dragged image reflects exactly what the user sees the moment
/// they begin the drag.
struct DragOutSource {
    let image: NSImage
    let arrows: [ArrowAnnotation]
    let texts: [TextAnnotation]
    let rectangles: [RectangleAnnotation]
    let suggestedFilename: String

    /// Returns nil when the canvas isn't ready to be dragged out (no image,
    /// editing in progress, etc.). The caller short-circuits the drag in that
    /// case.
    var isDraggable: Bool { image.size.width > 0 && image.size.height > 0 }
}

/// Predicate used by the drag-out NSView to decide whether a given canvas
/// point is "empty space" — meaning a drag-out should start there rather than
/// falling through to the annotation gesture layer below.
typealias DragOutHitTest = (CGPoint) -> Bool

/// Transparent overlay layered on top of the annotation gesture layer. It
/// returns itself from `hitTest(_:)` only when the click lands on empty image
/// background AND the canvas is in a state where a drag-out makes sense — so
/// drawing, selection, handles, text editing, and panning all keep working.
struct DragOutHandle: NSViewRepresentable {
    /// Producer for the current drag source. Resolved lazily at mouseDown so
    /// the snapshot reflects the latest annotations rather than whatever was
    /// captured at view-build time.
    let makeSource: () -> DragOutSource?
    /// Returns true when the given point in canvas-local coordinates is empty
    /// space (no annotation hit, no creation tool active, no crop mode, etc.).
    let isEmptySpace: DragOutHitTest
    /// Called when the user pressed and released without exceeding the drag
    /// threshold. Lets the canvas treat empty-space clicks as "deselect" even
    /// though our overlay caught the mouse-down.
    let onClickWithoutDrag: () -> Void

    func makeNSView(context: Context) -> DragOutNSView {
        let view = DragOutNSView()
        view.makeSource = makeSource
        view.isEmptySpace = isEmptySpace
        view.onClickWithoutDrag = onClickWithoutDrag
        return view
    }

    func updateNSView(_ nsView: DragOutNSView, context: Context) {
        nsView.makeSource = makeSource
        nsView.isEmptySpace = isEmptySpace
        nsView.onClickWithoutDrag = onClickWithoutDrag
    }
}

final class DragOutNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var makeSource: (() -> DragOutSource?)?
    var isEmptySpace: DragOutHitTest?
    var onClickWithoutDrag: (() -> Void)?

    /// PNG data for the in-flight drag, encoded once at mouseDown so both the
    /// pasteboard image rep and the file-promise writer can share it.
    private var pendingPNGData: Data?
    private var pendingFilename: String = "screenshot.png"

    /// AppKit's default drag-initiation distance. Matches Finder/Mail/etc.
    private static let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in our superview's coordinate space; convert before
        // consulting the canvas-space hit test.
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        guard isEmptySpace?(local) == true else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let source = makeSource?(), source.isDraggable else {
            onClickWithoutDrag?()
            return
        }

        // Track the pointer ourselves so a quick click without movement falls
        // through to a deselect callback rather than launching a drag session,
        // so clicking empty space deselects.
        let startLocation = event.locationInWindow
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]

        while let next = window?.nextEvent(matching: mask) {
            if next.type == .leftMouseUp {
                onClickWithoutDrag?()
                return
            }
            let dx = next.locationInWindow.x - startLocation.x
            let dy = next.locationInWindow.y - startLocation.y
            if hypot(dx, dy) >= Self.dragThreshold {
                startDrag(with: event, source: source)
                return
            }
        }
    }

    private func startDrag(with event: NSEvent, source: DragOutSource) {
        guard let pngData = pngData(for: source) else { return }

        pendingPNGData = pngData
        pendingFilename = source.suggestedFilename

        // A single writer that publishes both the file promise (for Finder)
        // and raw PNG data (for Slack/Mail/Messages). Using two separate
        // dragging items would make AppKit show a "2" multi-item badge.
        let provider = ImageFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        provider.pngData = pngData

        let dragImage = dragPreview(for: source.image)
        let dragOrigin = dragImageOrigin(for: dragImage, mouseLocation: event.locationInWindow)
        let dragFrame = NSRect(origin: dragOrigin, size: dragImage.size)

        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(dragFrame, contents: dragImage)

        beginDraggingSession(with: [item], event: event, source: self)
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .outsideApplication: return [.copy]
        case .withinApplication:  return []
        @unknown default:         return [.copy]
        }
    }

    // MARK: - NSFilePromiseProviderDelegate

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        pendingFilename
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let data = (filePromiseProvider as? ImageFilePromiseProvider)?.pngData ?? pendingPNGData
        guard let data else {
            completionHandler(ImageExportError.pngEncodingFailed)
            return
        }
        do {
            try data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.promiseQueue
    }

    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.jiminy-snippet.file-promise"
        return q
    }()

    // MARK: - Drag image / pasteboard helpers

    private func pngData(for source: DragOutSource) -> Data? {
        let rendered = ImageExporter.render(
            image: source.image,
            arrows: source.arrows,
            texts: source.texts,
            rectangles: source.rectangles
        )
        guard let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Builds a translucent thumbnail of the image to use as the drag preview.
    /// Caps the longest edge so massive screenshots don't yield an unwieldy
    /// drag image.
    private func dragPreview(for image: NSImage) -> NSImage {
        let maxEdge: CGFloat = 256
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let preview = NSImage(size: target)
        preview.lockFocus()
        defer { preview.unlockFocus() }
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 0.85
        )
        return preview
    }

    /// Centers the drag preview under the mouse cursor.
    private func dragImageOrigin(for previewImage: NSImage, mouseLocation: NSPoint) -> NSPoint {
        let local = convert(mouseLocation, from: nil)
        return NSPoint(
            x: local.x - previewImage.size.width / 2,
            y: local.y - previewImage.size.height / 2
        )
    }
}

/// `NSFilePromiseProvider` subclass that also advertises raw PNG data on the
/// pasteboard, so a single drag item satisfies both Finder (file promise) and
/// apps that read image data directly (Slack, Mail, Messages). One item ⇒ no
/// "2" multi-item badge during the drag.
final class ImageFilePromiseProvider: NSFilePromiseProvider {
    var pngData: Data?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .png { return pngData }
        return super.pasteboardPropertyList(forType: type)
    }

    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type == .png { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}
