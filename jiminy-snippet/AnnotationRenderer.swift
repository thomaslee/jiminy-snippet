//
//  AnnotationRenderer.swift
//  jiminy-snippet
//

import SwiftUI

/// Shared drawing constants used by both Canvas rendering and hit testing.
enum RenderConstants {
    static let arrowHitWidth: CGFloat = 20
    static let handleSize: CGFloat = 10
    static let handleHitRadius: CGFloat = 12
    static let textPaddingH: CGFloat = 4
    static let textPaddingV: CGFloat = 2

    // Shadow parameters (shared between Canvas and export rendering)
    static let shadowOffsetX: CGFloat = 1
    static let shadowOffsetY: CGFloat = 1
    static let shadowRadius: CGFloat = 1
    static let shadowOpacity: Double = 0.5

    /// The text's measured size plus padding on all sides.
    static func paddedTextSize(_ measured: CGSize) -> CGSize {
        CGSize(
            width: measured.width + textPaddingH * 2,
            height: measured.height + textPaddingV * 2
        )
    }

    /// Creates the NSFont used for text annotation rendering and measurement.
    static func textFont(size: CGFloat) -> NSFont {
        .boldSystemFont(ofSize: size)
    }
}

/// Draws annotations into a SwiftUI `GraphicsContext` (used by Canvas).
enum AnnotationRenderer {

    // MARK: - Arrow Drawing

    /// Draws an arrow with optional selection highlight. Pass `selected: true` to show selection chrome + handles.
    static func drawArrow(_ arrow: ArrowAnnotation, selected: Bool, in context: inout GraphicsContext) {
        let path = arrowPath(start: arrow.start, end: arrow.end)
        let style = StrokeStyle(lineWidth: arrow.lineWidth, lineCap: .round, lineJoin: .round)

        if selected {
            context.stroke(
                path,
                with: .color(.accentColor.opacity(0.4)),
                style: StrokeStyle(lineWidth: arrow.lineWidth + 8, lineCap: .round, lineJoin: .round)
            )
        }

        context.stroke(path, with: .color(arrow.color), style: style)

        if selected {
            drawHandle(at: arrow.start, in: &context)
            drawHandle(at: arrow.end, in: &context)
        }
    }

    // MARK: - Text Drawing

    /// Resolves and measures a text annotation. Call once, then pass results to `drawText` and `drawTextSelection`.
    static func resolveText(
        _ annotation: TextAnnotation,
        in context: GraphicsContext
    ) -> (resolved: GraphicsContext.ResolvedText, size: CGSize) {
        let text = Text(annotation.text.isEmpty ? " " : annotation.text)
            .font(.system(size: annotation.fontSize, weight: .bold))
            .foregroundStyle(annotation.color)
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        return (resolved, size)
    }

    /// Draws a text annotation using pre-resolved text.
    static func drawText(
        _ annotation: TextAnnotation,
        resolved: GraphicsContext.ResolvedText,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))
            ctx.addFilter(.shadow(
                color: .black.opacity(RenderConstants.shadowOpacity),
                radius: RenderConstants.shadowRadius,
                x: RenderConstants.shadowOffsetX,
                y: RenderConstants.shadowOffsetY
            ))
            let origin = CGPoint(x: RenderConstants.textPaddingH, y: RenderConstants.textPaddingV)
            ctx.draw(resolved, in: CGRect(origin: origin, size: size))
        }
    }

    /// Draws selection chrome and resize handle for a text annotation.
    static func drawTextSelection(
        _ annotation: TextAnnotation,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        let padded = RenderConstants.paddedTextSize(size)
        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))
            let path = Path(roundedRect: CGRect(origin: .zero, size: padded), cornerRadius: 4)
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
        let handlePoint = localToCanvas(
            CGPoint(x: padded.width + RenderConstants.handleSize / 2,
                    y: padded.height + RenderConstants.handleSize / 2),
            origin: annotation.position, angle: annotation.rotation
        )
        drawHandle(at: handlePoint, in: &context)
    }

    // MARK: - Handles

    static func drawHandle(at point: CGPoint, in context: inout GraphicsContext) {
        let size = RenderConstants.handleSize
        let rect = CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size
        )
        let circle = Path(ellipseIn: rect)
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(.accentColor), lineWidth: 2)
    }

    // MARK: - Text Measurement (NSFont, for hit testing)

    static func measureText(_ annotation: TextAnnotation) -> CGSize {
        let font = RenderConstants.textFont(size: annotation.fontSize)
        let string = annotation.text.isEmpty ? " " : annotation.text
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return NSAttributedString(string: string, attributes: attrs).size()
    }

    // MARK: - Geometry Helpers

    /// Transforms a point from a text annotation's local space to canvas coordinates.
    static func localToCanvas(_ local: CGPoint, origin: CGPoint, angle: Double) -> CGPoint {
        let rad = angle * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        return CGPoint(
            x: origin.x + local.x * cosA - local.y * sinA,
            y: origin.y + local.x * sinA + local.y * cosA
        )
    }

    /// Transforms a canvas point into a text annotation's local (unrotated) space.
    static func canvasToLocal(_ point: CGPoint, origin: CGPoint, angle: Double) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let rad = -angle * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        return CGPoint(x: dx * cosA - dy * sinA, y: dx * sinA + dy * cosA)
    }

    /// Builds a `Path` for an arrow (shaft + arrowhead wings).
    static func arrowPath(start: CGPoint, end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        if let wings = arrowHeadWings(tip: end, tail: start) {
            path.move(to: wings.left)
            path.addLine(to: end)
            path.addLine(to: wings.right)
        }
        return path
    }

    // MARK: - Private

    private static func arrowHeadWings(tip: CGPoint, tail: CGPoint) -> (left: CGPoint, right: CGPoint)? {
        let dx = tip.x - tail.x
        let dy = tip.y - tail.y
        let length = hypot(dx, dy)
        guard length > 0 else { return nil }

        let angle = atan2(dy, dx)
        let headLength = min(20, length * 0.3)
        let headAngle: CGFloat = .pi / 6

        return (
            left: CGPoint(
                x: tip.x - headLength * cos(angle - headAngle),
                y: tip.y - headLength * sin(angle - headAngle)
            ),
            right: CGPoint(
                x: tip.x - headLength * cos(angle + headAngle),
                y: tip.y - headLength * sin(angle + headAngle)
            )
        )
    }
}
