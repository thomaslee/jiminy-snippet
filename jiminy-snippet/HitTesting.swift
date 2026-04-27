//
//  HitTesting.swift
//  jiminy-snippet
//

import CoreGraphics
import Foundation

/// Position of a handle around a text annotation's bounding box.
enum HandlePosition: CaseIterable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottom, bottomRight

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }

    /// Returns the local (pre-rotation) position of this handle for a given scaled padded size.
    func localPoint(scaledSize: CGSize) -> CGPoint {
        let w = scaledSize.width
        let h = scaledSize.height
        switch self {
        case .topLeft:     return CGPoint(x: 0,   y: 0)
        case .top:         return CGPoint(x: w/2, y: 0)
        case .topRight:    return CGPoint(x: w,   y: 0)
        case .left:        return CGPoint(x: 0,   y: h/2)
        case .right:       return CGPoint(x: w,   y: h/2)
        case .bottomLeft:  return CGPoint(x: 0,   y: h)
        case .bottom:      return CGPoint(x: w/2, y: h)
        case .bottomRight: return CGPoint(x: w,   y: h)
        }
    }
}

/// Identifies which part of an annotation was hit.
enum HitZone {
    case body
    case startEndpoint
    case endEndpoint
    case handle(HandlePosition)
    case rotateHandle    // dedicated rotation handle floating above the top edge (text only)
}

/// Result of a hit test — either an arrow, text, or rectangle annotation hit.
enum AnnotationHit {
    case arrow(id: UUID, zone: HitZone)
    case text(id: UUID, zone: HitZone)
    case rectangle(id: UUID, zone: HitZone)

    var id: UUID {
        switch self {
        case .arrow(let id, _), .text(let id, _), .rectangle(let id, _): return id
        }
    }

    var zone: HitZone {
        switch self {
        case .arrow(_, let zone), .text(_, let zone), .rectangle(_, let zone): return zone
        }
    }

    var isBody: Bool {
        if case .body = zone { return true }
        return false
    }

    var isRotateHandle: Bool {
        if case .rotateHandle = zone { return true }
        return false
    }
}

/// Hit-tests a point against all annotations.
/// Checks texts first, then rectangles, then arrows — all in reverse order so
/// the topmost (most recently added) annotation wins.
/// Endpoint/resize handles are only hit-testable when the annotation is selected.
func hitTestAnnotations(
    at point: CGPoint,
    arrows: [ArrowAnnotation],
    texts: [TextAnnotation],
    rectangles: [RectangleAnnotation],
    selectedId: UUID?,
    textSizes: [UUID: CGSize]
) -> AnnotationHit? {
    // Check texts in reverse (topmost first)
    for annotation in texts.reversed() {
        guard let size = textSizes[annotation.id] else { continue }

        let localPoint = AnnotationRenderer.canvasToLocal(
            point, origin: annotation.position, angle: annotation.rotation
        )
        let padded = RenderConstants.paddedTextSize(size)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )
        let localRect = CGRect(origin: .zero, size: scaledSize)

        // Check handles first (only if selected). Rotate handle wins over the
        // top-center resize handle if both are within the hit radius — they
        // sit on the same vertical line so the rotate handle (further from
        // the box) only hits when the user reaches above the bounding box.
        if annotation.id == selectedId {
            let rotatePoint = AnnotationRenderer.rotateHandleLocalPoint(w: scaledSize.width)
            if distance(localPoint, rotatePoint) < RenderConstants.handleHitRadius {
                return .text(id: annotation.id, zone: .rotateHandle)
            }
            for pos in HandlePosition.allCases {
                let handlePoint = pos.localPoint(scaledSize: scaledSize)
                if distance(localPoint, handlePoint) < RenderConstants.handleHitRadius {
                    return .text(id: annotation.id, zone: .handle(pos))
                }
            }
        }

        // Check body
        if localRect.contains(localPoint) {
            return .text(id: annotation.id, zone: .body)
        }
    }

    // Check rectangles in reverse
    for rectangle in rectangles.reversed() {
        let bounds = rectangle.rect.standardized
        guard bounds.width > 0, bounds.height > 0 else { continue }

        // Convert the canvas-space hit point into the rect's local frame
        // (origin at top-left, +x along the rotated edge), so handle and body
        // tests can be written as if the rect were axis-aligned.
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let centered = AnnotationRenderer.canvasToLocal(
            point, origin: center, angle: rectangle.rotation
        )
        let localPoint = CGPoint(x: centered.x + bounds.width / 2,
                                 y: centered.y + bounds.height / 2)
        let localBounds = CGRect(origin: .zero, size: bounds.size)

        // Check handles first (only if selected). Rotation handle wins over
        // the top-center resize handle when both are within reach.
        if rectangle.id == selectedId {
            let rotatePoint = AnnotationRenderer.rotateHandleLocalPoint(w: bounds.width)
            if distance(localPoint, rotatePoint) < RenderConstants.handleHitRadius {
                return .rectangle(id: rectangle.id, zone: .rotateHandle)
            }
            for pos in HandlePosition.allCases {
                let handlePoint = pos.localPoint(scaledSize: bounds.size)
                if distance(localPoint, handlePoint) < RenderConstants.handleHitRadius {
                    return .rectangle(id: rectangle.id, zone: .handle(pos))
                }
            }
        }

        // Check body. Filled rectangles are hit anywhere inside the bounds;
        // outlined rectangles are hit only within a narrow band around the
        // stroke so the user can click through to annotations sitting
        // "behind" an empty rectangle.
        switch rectangle.style {
        case .filled:
            if localBounds.contains(localPoint) {
                return .rectangle(id: rectangle.id, zone: .body)
            }
        case .outlined:
            let tolerance = max(8, rectangle.lineWidth * 2.5 / 2 + 4)
            let outer = localBounds.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = localBounds.insetBy(dx: tolerance, dy: tolerance)
            // inner.isNull when the rectangle is narrower than 2×tolerance —
            // treat tiny outlined rectangles as fully hit-testable so they
            // don't become impossible to grab.
            let innerHit = inner.isNull ? false : inner.contains(localPoint)
            if outer.contains(localPoint), !innerHit {
                return .rectangle(id: rectangle.id, zone: .body)
            }
        }
    }

    // Check arrows in reverse
    for arrow in arrows.reversed() {
        // Check endpoints first (only if selected)
        if arrow.id == selectedId {
            if distance(point, arrow.start) < RenderConstants.handleHitRadius {
                return .arrow(id: arrow.id, zone: .startEndpoint)
            }
            if distance(point, arrow.end) < RenderConstants.handleHitRadius {
                return .arrow(id: arrow.id, zone: .endEndpoint)
            }
        }

        // Check body (distance to line segment)
        let dist = distanceToSegment(point: point, segStart: arrow.start, segEnd: arrow.end)
        if dist < RenderConstants.arrowHitWidth / 2 {
            return .arrow(id: arrow.id, zone: .body)
        }
    }

    return nil
}

// MARK: - Geometry Helpers

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}

/// Perpendicular distance from `point` to the line segment from `segStart` to `segEnd`.
private func distanceToSegment(point: CGPoint, segStart: CGPoint, segEnd: CGPoint) -> CGFloat {
    let dx = segEnd.x - segStart.x
    let dy = segEnd.y - segStart.y
    let lengthSq = dx * dx + dy * dy

    guard lengthSq > 0 else {
        return distance(point, segStart)
    }

    // Project point onto the segment, clamped to [0, 1]
    let t = max(0, min(1, ((point.x - segStart.x) * dx + (point.y - segStart.y) * dy) / lengthSq))
    let projection = CGPoint(
        x: segStart.x + t * dx,
        y: segStart.y + t * dy
    )
    return distance(point, projection)
}
