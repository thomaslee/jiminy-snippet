//
//  CanvasGeometry.swift
//  jiminy-snippet
//
//  Created by Tom on 7/3/26.
//
//  Pure geometry used by canvas interactions: drag rects, marquee bounding
//  boxes, and rotated-rectangle resize math. Nothing here touches SwiftUI
//  state, so all of it is exercisable from unit tests.
//

import CoreGraphics
import Foundation

extension CGRect {
    /// The axis-aligned rectangle spanning two arbitrary corner points —
    /// typically the anchor and live location of a drag.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}

// MARK: - Marquee Bounding Boxes

extension ArrowAnnotation {
    /// Axis-aligned box around both endpoints, padded to roughly the arrow
    /// head's half-width so a marquee picks up the full visual extent of the
    /// arrow rather than just the centerline.
    var boundingBox: CGRect {
        let box = CGRect(from: start, to: end)
        let pad = lineWidth * 3.2
        return box.insetBy(dx: -pad, dy: -pad)
    }
}

extension RectangleAnnotation {
    /// Axis-aligned box enclosing the (possibly rotated) rectangle.
    var boundingBox: CGRect {
        let bounds = rect.standardized
        guard rotation != 0 else { return bounds }
        let rad = rotation * .pi / 180
        let cosA = abs(cos(rad))
        let sinA = abs(sin(rad))
        let w = bounds.width * cosA + bounds.height * sinA
        let h = bounds.width * sinA + bounds.height * cosA
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }
}

extension TextAnnotation {
    /// Axis-aligned box enclosing the scaled, rotated text box.
    /// `measuredSize` is the unscaled text measurement (see
    /// `AnnotationRenderer.measureText`), passed in so this stays pure.
    func boundingBox(measuredSize: CGSize) -> CGRect {
        let padded = RenderConstants.paddedTextSize(measuredSize)
        let scaledSize = CGSize(
            width: padded.width * scaleX,
            height: padded.height * scaleY
        )
        guard rotation != 0 else {
            return CGRect(origin: position, size: scaledSize)
        }
        let rad = rotation * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let corners: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: scaledSize.width, y: 0),
            CGPoint(x: scaledSize.width, y: scaledSize.height),
            CGPoint(x: 0, y: scaledSize.height),
        ]
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for c in corners {
            let x = position.x + c.x * cosA - c.y * sinA
            let y = position.y + c.x * sinA + c.y * cosA
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Returns the ids of every annotation whose axis-aligned bounding box
/// intersects `rect`. Touching counts (Finder-style), so a marquee that
/// merely grazes the edge of an annotation is enough to select it.
func annotationsIntersecting(
    _ rect: CGRect,
    annotations: [Annotation],
    textSizes: [UUID: CGSize]
) -> Set<UUID> {
    var ids: Set<UUID> = []
    for annotation in annotations {
        let box: CGRect?
        switch annotation {
        case .arrow(let arrow):
            box = arrow.boundingBox
        case .rectangle(let rectangle):
            box = rectangle.boundingBox
        case .text(let text):
            box = textSizes[text.id].map { text.boundingBox(measuredSize: $0) }
        }
        if let box, box.intersects(rect) {
            ids.insert(annotation.id)
        }
    }
    return ids
}

// MARK: - Rotated Rectangle Resize

/// Computes the new rect produced by dragging a handle on a rotated
/// rectangle. `localTranslation` is the canvas-space drag delta already
/// rotated into the rect's local frame, so handle math can be done as if
/// the rect were axis-aligned. The result preserves the anchor (the
/// edge/corner opposite to the dragged handle) at its canvas position.
/// May be non-standardized while dragging past the opposite edge —
/// callers standardize at the end of the drag.
func resizedRotatedRect(
    initial: CGRect,
    rotation: Double,
    handle: HandlePosition,
    localTranslation: CGSize
) -> CGRect {
    // Work in a local frame centred on the initial rect's center, where
    // the unrotated rect spans (-w/2 ... w/2, -h/2 ... h/2).
    let halfW = initial.width / 2
    let halfH = initial.height / 2
    var lMinX = -halfW, lMaxX = halfW
    var lMinY = -halfH, lMaxY = halfH

    let dx = localTranslation.width
    let dy = localTranslation.height
    switch handle {
    case .topLeft:     lMinX += dx; lMinY += dy
    case .top:                      lMinY += dy
    case .topRight:    lMaxX += dx; lMinY += dy
    case .left:        lMinX += dx
    case .right:       lMaxX += dx
    case .bottomLeft:  lMinX += dx; lMaxY += dy
    case .bottom:                   lMaxY += dy
    case .bottomRight: lMaxX += dx; lMaxY += dy
    }

    let newWidth = lMaxX - lMinX
    let newHeight = lMaxY - lMinY
    // Local-frame center of the new rect, relative to the initial center.
    let localCenter = CGPoint(x: (lMinX + lMaxX) / 2, y: (lMinY + lMaxY) / 2)

    // Rotate the local center back into canvas space and add to the
    // initial center to find where the new rect's center should sit.
    let rad = rotation * .pi / 180
    let cosA = cos(rad), sinA = sin(rad)
    let initialCenter = CGPoint(x: initial.midX, y: initial.midY)
    let newCenter = CGPoint(
        x: initialCenter.x + localCenter.x * cosA - localCenter.y * sinA,
        y: initialCenter.y + localCenter.x * sinA + localCenter.y * cosA
    )

    return CGRect(
        x: newCenter.x - newWidth / 2,
        y: newCenter.y - newHeight / 2,
        width: newWidth,
        height: newHeight
    )
}
