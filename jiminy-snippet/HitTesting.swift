//
//  HitTesting.swift
//  jiminy-snippet
//

import CoreGraphics
import Foundation

/// Identifies which part of an annotation was hit.
enum HitZone {
    case body
    case startEndpoint
    case endEndpoint
    case resizeHandle
}

/// Result of a hit test — either an arrow or text annotation hit.
enum AnnotationHit {
    case arrow(id: UUID, zone: HitZone)
    case text(id: UUID, zone: HitZone)
}

/// Hit-tests a point against all annotations.
/// Checks texts first (topmost), then arrows, both in reverse order.
/// Endpoint/resize handles are only hit-testable when the annotation is selected.
func hitTestAnnotations(
    at point: CGPoint,
    arrows: [ArrowAnnotation],
    texts: [TextAnnotation],
    selectedId: UUID?,
    textSizes: [UUID: CGSize]
) -> AnnotationHit? {
    // Check texts in reverse (topmost first)
    for annotation in texts.reversed() {
        guard let size = textSizes[annotation.id] else { continue }

        // Check resize handle first (only if selected)
        if annotation.id == selectedId {
            let handlePoint = AnnotationRenderer.resizeHandlePoint(for: annotation, measuredSize: size)
            if distance(point, handlePoint) < RenderConstants.handleHitRadius {
                return .text(id: annotation.id, zone: .resizeHandle)
            }
        }

        // Check body
        let rect = AnnotationRenderer.textBoundingRect(for: annotation, measuredSize: size)
        if rect.contains(point) {
            return .text(id: annotation.id, zone: .body)
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
