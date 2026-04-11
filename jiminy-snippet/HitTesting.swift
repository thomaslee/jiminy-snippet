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
    case exterior        // outside the body but within the grab margin (selected text only)
    case startEndpoint
    case endEndpoint
    case handle(HandlePosition)
}

/// Result of a hit test — either an arrow, text, or rectangle annotation hit.
enum AnnotationHit {
    case arrow(id: UUID, zone: HitZone)
    case text(id: UUID, zone: HitZone)
    case rectangle(id: UUID, zone: HitZone)
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

        // Check handles first (only if selected)
        if annotation.id == selectedId {
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

        // Check exterior margin (only for the selected annotation — used for rotation)
        if annotation.id == selectedId {
            let margin: CGFloat = 20
            let expandedRect = localRect.insetBy(dx: -margin, dy: -margin)
            if expandedRect.contains(localPoint) {
                return .text(id: annotation.id, zone: .exterior)
            }
        }
    }

    // Check rectangles in reverse
    for rectangle in rectangles.reversed() {
        let bounds = rectangle.rect.standardized
        guard bounds.width > 0, bounds.height > 0 else { continue }

        // Check handles first (only if selected)
        if rectangle.id == selectedId {
            for pos in HandlePosition.allCases {
                let local = pos.localPoint(scaledSize: bounds.size)
                let handlePoint = CGPoint(x: bounds.minX + local.x, y: bounds.minY + local.y)
                if distance(point, handlePoint) < RenderConstants.handleHitRadius {
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
            if bounds.contains(point) {
                return .rectangle(id: rectangle.id, zone: .body)
            }
        case .outlined:
            let tolerance = max(8, rectangle.lineWidth * 2.5 / 2 + 4)
            let outer = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = bounds.insetBy(dx: tolerance, dy: tolerance)
            // inner.isNull when the rectangle is narrower than 2×tolerance —
            // treat tiny outlined rectangles as fully hit-testable so they
            // don't become impossible to grab.
            let innerHit = inner.isNull ? false : inner.contains(point)
            if outer.contains(point), !innerHit {
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
