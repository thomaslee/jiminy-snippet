//
//  CanvasDragController.swift
//  jiminy-snippet
//
//  Created by Tom on 7/3/26.
//

import AppKit
import SwiftUI

/// Which axis a text scaling operation affects.
enum ScaleAxis {
    case uniform    // corner handles — both axes
    case horizontal // left/right handles
    case vertical   // top/bottom handles
}

/// Which endpoints of an arrow follow a translation drag.
struct ArrowEndpointMask: OptionSet {
    let rawValue: Int
    static let start = ArrowEndpointMask(rawValue: 1 << 0)
    static let end   = ArrowEndpointMask(rawValue: 1 << 1)
    static let both: ArrowEndpointMask = [.start, .end]
}

/// The drag interaction currently in flight on the canvas. Creation and
/// selection cases carry the live geometry the canvas needs to draw previews;
/// manipulation cases carry the initial geometry so every update can be
/// computed from a stable base rather than compounding per-frame deltas.
enum DragOperation {
    case none
    case creatingArrow(start: CGPoint, end: CGPoint)
    case creatingRectangle(start: CGPoint, end: CGPoint)
    case creatingPixelate(start: CGPoint, end: CGPoint)
    case croppingSelection(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint, mask: ArrowEndpointMask)
    case movingRectangle(id: UUID, initialRect: CGRect)
    case resizingRectangle(
        id: UUID,
        initialRect: CGRect,
        handle: HandlePosition,
        rotation: Double
    )
    case rotatingRectangle(
        id: UUID,
        initialRotation: Double,
        referenceAngle: Double,
        center: CGPoint
    )
    case movingText(id: UUID, initialPosition: CGPoint)
    case scalingText(
        id: UUID,
        axis: ScaleAxis,
        initialScaleX: CGFloat,
        initialScaleY: CGFloat,
        center: CGPoint,
        paddedWidth: CGFloat,
        paddedHeight: CGFloat,
        initialRef: CGFloat
    )
    case rotatingText(
        id: UUID,
        initialRotation: Double,
        referenceAngle: Double,
        center: CGPoint,
        paddedWidth: CGFloat,
        paddedHeight: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    )
    /// Translates several annotations together — the body-drag flavour of a
    /// multi-selection. Each entry stores the annotation as it was at drag
    /// start so the translation can be applied from a stable base.
    case movingMultiple(initial: [UUID: Annotation])
    /// Drag-rectangle (marquee) for selecting annotations en masse. Live-
    /// updates the document's selection as the user drags. `initialSelection`
    /// is the set carried over from before the drag — non-empty only when
    /// `additive` is true (Shift held), so plain marquees replace selection.
    case marqueeSelecting(
        start: CGPoint,
        end: CGPoint,
        initialSelection: Set<UUID>,
        additive: Bool
    )
}

/// The canvas's drag state machine. Owns the in-flight `DragOperation`,
/// decides which operation a fresh drag starts (via hit testing), and applies
/// each update's mutations to the document. Input state (modifier keys, the
/// active tool, measured text sizes) arrives through `Context` rather than
/// being read from AppKit globals, so the machine can be driven from unit
/// tests without a live event stream.
@MainActor
struct CanvasDragController {
    /// A per-event snapshot of everything a drag transition needs from the
    /// canvas. Built fresh for each gesture callback so modifier keys and
    /// tool state are always current.
    struct Context {
        let document: AnnotationDocument
        let imageSize: CGSize
        let selectedTool: AnnotationTool?
        let selectedColor: Color
        let rectangleFillStyle: RectangleFillStyle
        let cropMode: Bool
        let shiftPressed: Bool
        let textSizes: [UUID: CGSize]
    }

    /// View-state consequences of a finished drag that the document can't
    /// absorb — the owning view applies these to its own state.
    enum EndEffect: Equatable {
        case none
        /// A creation drag (arrow/rectangle/pixelate) finished — the owner
        /// deactivates the drawing tool.
        case toolFinished
        /// Crop selection ended. Non-nil means a viable region was selected
        /// and the crop should be applied; nil means the drag was too small
        /// and any previous selection should be cleared.
        case cropSelected(CGRect?)
    }

    private(set) var operation: DragOperation = .none

    // MARK: - Drag Updates

    mutating func dragChanged(
        location point: CGPoint,
        translation: CGSize,
        startLocation: CGPoint,
        context: Context
    ) {
        let document = context.document

        switch operation {
        case .none:
            guard let op = begin(at: startLocation, context: context) else { return }
            // Crop selection only touches `cropRect` (the actual crop is
            // recorded later, in AnnotationDocument.applyCrop) and marquee
            // only touches the selection — neither is undoable state, so
            // recording a snapshot would burn a no-op undo slot.
            switch op {
            case .croppingSelection, .marqueeSelecting:
                break
            case .creatingPixelate:
                // Pixelation records its own patch-sized undo entry when it
                // commits (AnnotationDocument.applyPixelation) — a full
                // snapshot here would pin the entire pre-edit bitmap for a
                // localized edit.
                break
            default:
                document.recordSnapshot()
            }
            operation = op
            // Re-enter so the current translation is applied immediately,
            // rather than waiting one frame for the next drag event.
            dragChanged(
                location: point, translation: translation,
                startLocation: startLocation, context: context
            )

        case .creatingArrow(let start, _):
            operation = .creatingArrow(start: start, end: point)

        case .creatingRectangle(let start, _):
            operation = .creatingRectangle(start: start, end: point)

        case .creatingPixelate(let start, _):
            operation = .creatingPixelate(start: start, end: point)

        case .croppingSelection(let start, _):
            operation = .croppingSelection(start: start, end: point)

        case .movingArrow(let id, let initialStart, let initialEnd, let mask):
            document.annotations.updateArrow(id: id) { arrow in
                if mask.contains(.start) { arrow.start = initialStart + translation }
                if mask.contains(.end)   { arrow.end   = initialEnd + translation }
            }

        case .movingRectangle(let id, let initial):
            document.annotations.updateRectangle(id: id) {
                $0.rect = initial.offsetBy(dx: translation.width, dy: translation.height)
            }

        case .resizingRectangle(let id, let initial, let handle, let rotation):
            // Project the canvas-space drag translation into the rect's local
            // rotated frame so dragging the "right" handle moves along the
            // rect's local x axis even when the rect is at a non-zero angle.
            let rad = -rotation * .pi / 180
            let cosA = cos(rad), sinA = sin(rad)
            let localTrans = CGSize(
                width:  translation.width * cosA - translation.height * sinA,
                height: translation.width * sinA + translation.height * cosA
            )
            document.annotations.updateRectangle(id: id) {
                $0.rect = resizedRotatedRect(
                    initial: initial, rotation: rotation,
                    handle: handle, localTranslation: localTrans
                )
            }

        case .rotatingRectangle(let id, let initialRotation, let referenceAngle, let center):
            let shiftPressed = context.shiftPressed
            document.annotations.updateRectangle(id: id) { rectangle in
                let currentAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
                let raw = initialRotation + (currentAngle - referenceAngle)
                rectangle.rotation = snappedRotation(raw, shiftPressed: shiftPressed)
                // `rect` is the unrotated bounds and the renderer pivots
                // around its center, so leaving `rect` untouched keeps the
                // rotation anchored at `center`.
            }

        case .movingText(let id, let initial):
            document.annotations.updateText(id: id) { $0.position = initial + translation }

        case .scalingText(let id, let axis, let initialScaleX, let initialScaleY,
                         let center, let paddedWidth, let paddedHeight, let initialRef):
            guard initialRef > 0.001 else { break }
            document.annotations.updateText(id: id) { text in
                let rad = text.rotation * .pi / 180
                var newSX = initialScaleX
                var newSY = initialScaleY

                switch axis {
                case .uniform:
                    let dist = hypot(point.x - center.x, point.y - center.y)
                    let factor = dist / initialRef
                    newSX = initialScaleX * factor
                    newSY = initialScaleY * factor

                case .horizontal:
                    let axisX = cos(rad), axisY = sin(rad)
                    let proj = (point.x - center.x) * axisX + (point.y - center.y) * axisY
                    newSX = initialScaleX * abs(proj) / initialRef

                case .vertical:
                    let axisX = -sin(rad), axisY = cos(rad)
                    let proj = (point.x - center.x) * axisX + (point.y - center.y) * axisY
                    newSY = initialScaleY * abs(proj) / initialRef
                }

                newSX = max(0.2, newSX)
                newSY = max(0.2, newSY)
                text.scaleX = newSX
                text.scaleY = newSY

                // Reposition so center stays fixed
                let newLocalCenter = CGPoint(
                    x: paddedWidth * newSX / 2,
                    y: paddedHeight * newSY / 2
                )
                text.position = CGPoint(
                    x: center.x - (newLocalCenter.x * cos(rad) - newLocalCenter.y * sin(rad)),
                    y: center.y - (newLocalCenter.x * sin(rad) + newLocalCenter.y * cos(rad))
                )
            }

        case .marqueeSelecting(let start, _, let initialSelection, let additive):
            let rect = CGRect(from: start, to: point)
            let inside = annotationsIntersecting(
                rect, annotations: document.annotations, textSizes: context.textSizes
            )
            document.selectedAnnotationIds = additive
                ? initialSelection.union(inside)
                : inside
            operation = .marqueeSelecting(
                start: start, end: point,
                initialSelection: initialSelection, additive: additive
            )

        case .movingMultiple(let initialSnapshots):
            for (id, initial) in initialSnapshots {
                document.annotations.update(id: id) { $0 = initial.translated(by: translation) }
            }

        case .rotatingText(let id, let initialRotation, let referenceAngle, let center,
                           let paddedWidth, let paddedHeight, let scaleX, let scaleY):
            let shiftPressed = context.shiftPressed
            document.annotations.updateText(id: id) { text in
                let currentAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
                let newRotation = snappedRotation(
                    initialRotation + (currentAngle - referenceAngle),
                    shiftPressed: shiftPressed
                )
                text.rotation = newRotation

                // The renderer pivots around `position` (the box's top-left),
                // so rotating in place would whip the text around that corner.
                // Recompute `position` each frame so the box's visual center
                // stays pinned at `center` regardless of angle.
                let rad = newRotation * .pi / 180
                let halfW = paddedWidth * scaleX / 2
                let halfH = paddedHeight * scaleY / 2
                let cosA = cos(rad), sinA = sin(rad)
                text.position = CGPoint(
                    x: center.x - (halfW * cosA - halfH * sinA),
                    y: center.y - (halfW * sinA + halfH * cosA)
                )
            }
        }
    }

    /// Commits whatever operation was in flight and resets to `.none`.
    /// Returns the view-state effect the owner still needs to apply.
    mutating func dragEnded(location: CGPoint, context: Context) -> EndEffect {
        defer { operation = .none }
        let document = context.document

        switch operation {
        case .creatingArrow(let start, _):
            let arrow = ArrowAnnotation(
                start: start,
                end: location,
                color: context.selectedColor,
                lineWidth: ArrowAnnotation.defaultLineWidth(for: context.imageSize)
            )
            document.annotations.append(.arrow(arrow))
            document.selectedAnnotationIds = [arrow.id]
            return .toolFinished

        case .creatingRectangle(let start, _):
            let rect = CGRect(from: start, to: location)
            if rect.width > 1, rect.height > 1 {
                let rectangle = RectangleAnnotation(
                    rect: rect,
                    color: context.selectedColor,
                    lineWidth: RectangleAnnotation.defaultLineWidth(for: context.imageSize),
                    style: context.rectangleFillStyle
                )
                document.annotations.append(.rectangle(rectangle))
                document.selectedAnnotationIds = [rectangle.id]
            }
            return .toolFinished

        case .creatingPixelate(let start, _):
            let rect = CGRect(from: start, to: location)
            if rect.width > 1, rect.height > 1 {
                document.applyPixelation(rect: rect)
            }
            // Nothing to clean up on a degenerate drag: pixelation only
            // records its undo entry when it actually commits.
            return .toolFinished

        case .resizingRectangle(let id, _, _, _):
            // Normalize at the end of a resize so flipped rects are stored
            // with positive width/height. Hit testing already standardizes,
            // but keeping the stored value tidy avoids surprises elsewhere.
            document.annotations.updateRectangle(id: id) { $0.rect = $0.rect.standardized }
            return .none

        case .croppingSelection(let start, _):
            let imageBounds = CGRect(origin: .zero, size: context.imageSize)
            let rect = CGRect(from: start, to: location).intersection(imageBounds)
            if rect.width > 1, rect.height > 1 {
                return .cropSelected(rect)
            }
            return .cropSelected(nil)

        default:
            return .none
        }
    }

    // MARK: - Drag Start

    /// Decides what kind of drag the user is starting at `startPoint`.
    /// Mutates selection state as a side-effect, but only returns a
    /// `DragOperation` when an actual drag should begin.
    private func begin(at startPoint: CGPoint, context: Context) -> DragOperation? {
        let document = context.document

        if context.cropMode {
            return .croppingSelection(start: startPoint, end: startPoint)
        }

        if context.selectedTool == .arrow {
            document.selectedAnnotationIds.removeAll()
            return .creatingArrow(start: startPoint, end: startPoint)
        }

        if context.selectedTool == .rectangle {
            document.selectedAnnotationIds.removeAll()
            return .creatingRectangle(start: startPoint, end: startPoint)
        }

        if context.selectedTool == .pixelate {
            document.selectedAnnotationIds.removeAll()
            return .creatingPixelate(start: startPoint, end: startPoint)
        }

        let isShift = context.shiftPressed

        // Empty-space drag = marquee selection. Shift makes it additive (extends
        // the existing selection); plain marquee replaces. Holding Option while
        // dragging from empty space takes the drag-out path instead, but that's
        // routed through DragOutHandle and never reaches this method.
        guard let hit = hitTest(at: startPoint, context: context) else {
            let initial = isShift ? document.selectedAnnotationIds : []
            if !isShift {
                document.selectedAnnotationIds.removeAll()
            }
            return .marqueeSelecting(
                start: startPoint, end: startPoint,
                initialSelection: initial, additive: isShift
            )
        }

        // Shift-drag on an annotation: bail. Shift is reserved for the click-
        // toggle behavior, and multi-selection drag of one item with shift held
        // would be ambiguous (toggle? augment? translate?). Rotation handles
        // are exempt — shift-drag from the rotate handle snaps to 45°.
        if isShift && !hit.isRotateHandle {
            return nil
        }

        // Body-drag on any member of a multi-selection moves the whole group
        // together. Handle drags don't reach this branch — handles aren't
        // drawn or hit-tested while multi-selected — so this is purely the
        // translate-as-a-unit case.
        let hitId = hit.id
        if hit.isBody,
           document.selectedAnnotationIds.contains(hitId),
           document.selectedAnnotationIds.count > 1 {
            return beginMovingMultiple(document: document)
        }

        switch hit {
        case .arrow(let id, let zone):
            document.selectedAnnotationIds = [id]
            guard let arrow = document.annotations.first(where: { $0.id == id })?.arrow else {
                return nil
            }
            let mask: ArrowEndpointMask
            switch zone {
            case .startEndpoint: mask = .start
            case .endEndpoint:   mask = .end
            case .body:          mask = .both
            default:             return nil
            }
            return .movingArrow(
                id: id, initialStart: arrow.start, initialEnd: arrow.end, mask: mask
            )

        case .text(let id, let zone):
            document.selectedAnnotationIds = [id]
            guard let annotation = document.annotations.first(where: { $0.id == id })?.text else {
                return nil
            }
            switch zone {
            case .handle(let handlePos):
                return beginTextScaling(for: annotation, handle: handlePos)
            case .rotateHandle:
                return beginRotation(for: annotation, from: startPoint)
            case .body:
                return .movingText(id: id, initialPosition: annotation.position)
            default:
                return nil
            }

        case .rectangle(let id, let zone):
            document.selectedAnnotationIds = [id]
            guard let rectangle = document.annotations.first(where: { $0.id == id })?.rectangle
            else { return nil }
            switch zone {
            case .body:
                return .movingRectangle(id: id, initialRect: rectangle.rect)
            case .handle(let handlePos):
                return .resizingRectangle(
                    id: id,
                    initialRect: rectangle.rect.standardized,
                    handle: handlePos,
                    rotation: rectangle.rotation
                )
            case .rotateHandle:
                return beginRectangleRotation(for: rectangle, from: startPoint)
            default:
                return nil
            }
        }
    }

    private func hitTest(at point: CGPoint, context: Context) -> AnnotationHit? {
        let selection = context.document.selectedAnnotationIds
        return hitTestAnnotations(
            at: point,
            annotations: context.document.annotations,
            selectedId: selection.count == 1 ? selection.first : nil,
            textSizes: context.textSizes
        )
    }

    /// Snapshots every selected annotation so a drag can translate them all
    /// from a stable base.
    private func beginMovingMultiple(document: AnnotationDocument) -> DragOperation {
        let ids = document.selectedAnnotationIds
        var initial: [UUID: Annotation] = [:]
        for annotation in document.annotations where ids.contains(annotation.id) {
            initial[annotation.id] = annotation
        }
        return .movingMultiple(initial: initial)
    }

    /// Builds a `rotatingRectangle` drag operation anchored at the rect's
    /// visual center.
    private func beginRectangleRotation(
        for rectangle: RectangleAnnotation,
        from startPoint: CGPoint
    ) -> DragOperation {
        let bounds = rectangle.rect.standardized
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let referenceAngle = atan2(
            startPoint.y - center.y,
            startPoint.x - center.x
        ) * 180 / .pi
        return .rotatingRectangle(
            id: rectangle.id,
            initialRotation: rectangle.rotation,
            referenceAngle: referenceAngle,
            center: center
        )
    }

    /// Builds a `rotatingText` drag operation anchored at the annotation's center.
    private func beginRotation(
        for annotation: TextAnnotation,
        from startPoint: CGPoint
    ) -> DragOperation {
        let padded = RenderConstants.paddedTextSize(AnnotationRenderer.measureText(annotation))
        let center = textCenter(for: annotation)
        let referenceAngle = atan2(
            startPoint.y - center.y,
            startPoint.x - center.x
        ) * 180 / .pi
        return .rotatingText(
            id: annotation.id,
            initialRotation: annotation.rotation,
            referenceAngle: referenceAngle,
            center: center,
            paddedWidth: padded.width,
            paddedHeight: padded.height,
            scaleX: annotation.scaleX,
            scaleY: annotation.scaleY
        )
    }

    /// Builds a `scalingText` drag operation for the given handle.
    /// Decides scaling axis (uniform/horizontal/vertical) and the reference distance
    /// against which subsequent drag distances are normalised.
    private func beginTextScaling(
        for annotation: TextAnnotation,
        handle handlePos: HandlePosition
    ) -> DragOperation {
        let measured = AnnotationRenderer.measureText(annotation)
        let padded = RenderConstants.paddedTextSize(measured)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )
        let center = textCenter(for: annotation)

        let axis: ScaleAxis
        let initialRef: CGFloat
        if handlePos.isCorner {
            axis = .uniform
            let handleLocal = handlePos.localPoint(scaledSize: scaledSize)
            let handleCanvas = AnnotationRenderer.localToCanvas(
                handleLocal, origin: annotation.position, angle: annotation.rotation
            )
            initialRef = hypot(handleCanvas.x - center.x, handleCanvas.y - center.y)
        } else if handlePos == .left || handlePos == .right {
            axis = .horizontal
            initialRef = padded.width * annotation.scaleX / 2
        } else {
            axis = .vertical
            initialRef = padded.height * annotation.scaleY / 2
        }

        return .scalingText(
            id: annotation.id,
            axis: axis,
            initialScaleX: annotation.scaleX,
            initialScaleY: annotation.scaleY,
            center: center,
            paddedWidth: padded.width,
            paddedHeight: padded.height,
            initialRef: initialRef
        )
    }

    // MARK: - Helpers

    /// If shift is held, snaps to the nearest 45° increment (0/45/90/...) so
    /// users can lock annotations to canvas-aligned angles. Otherwise returns
    /// `raw` unchanged.
    private func snappedRotation(_ raw: Double, shiftPressed: Bool) -> Double {
        guard shiftPressed else { return raw }
        return (raw / 45).rounded() * 45
    }

    /// Returns the center of a text annotation's scaled bounding box in canvas space.
    private func textCenter(for annotation: TextAnnotation) -> CGPoint {
        let padded = RenderConstants.paddedTextSize(AnnotationRenderer.measureText(annotation))
        let localCenter = CGPoint(
            x: padded.width * annotation.scaleX / 2,
            y: padded.height * annotation.scaleY / 2
        )
        return AnnotationRenderer.localToCanvas(
            localCenter, origin: annotation.position, angle: annotation.rotation
        )
    }
}

/// Translates a point by a SwiftUI gesture translation.
private func + (point: CGPoint, translation: CGSize) -> CGPoint {
    CGPoint(x: point.x + translation.width, y: point.y + translation.height)
}
