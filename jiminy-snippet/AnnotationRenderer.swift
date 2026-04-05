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
    static let handleArmLength: CGFloat = 10
    static let handleLineWidth: CGFloat = 2
    static let handleOutlineWidth: CGFloat = 4.5
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

    /// Draws a text annotation using pre-resolved text, applying scaleX/scaleY.
    static func drawText(
        _ annotation: TextAnnotation,
        resolved: GraphicsContext.ResolvedText,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))
            ctx.scaleBy(x: annotation.scaleX, y: annotation.scaleY)
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

    /// Draws selection chrome and handles for a text annotation.
    static func drawTextSelection(
        _ annotation: TextAnnotation,
        size: CGSize,
        handleMode: HandleMode,
        in context: inout GraphicsContext
    ) {
        let padded = RenderConstants.paddedTextSize(size)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )
        let w = scaledSize.width
        let h = scaledSize.height
        let arm = RenderConstants.handleArmLength

        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))

            // Selection border
            let rect = CGRect(origin: .zero, size: scaledSize)
            ctx.stroke(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(.accentColor), lineWidth: 2
            )

            if handleMode == .resize {
                drawResizeCorners(w: w, h: h, arm: arm, in: &ctx)
                drawResizeSideTicks(w: w, h: h, in: &ctx)
            } else {
                drawRotateCorners(w: w, h: h, radius: arm, in: &ctx)
            }
        }
    }

    // MARK: - Handles

    /// Circle handle used for arrow endpoints.
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

    // MARK: - Resize Handles (L-shaped corner brackets + side ticks)

    private static func drawResizeCorners(
        w: CGFloat, h: CGFloat, arm: CGFloat,
        in context: inout GraphicsContext
    ) {
        // Each corner: an L-shaped bracket with arms extending along the bounding box edges.
        let corners: [(CGPoint, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            // (corner point, arm1 dx, arm1 dy, arm2 dx, arm2 dy)
            (CGPoint(x: 0, y: 0),  1,  0,  0,  1),  // topLeft: right + down
            (CGPoint(x: w, y: 0), -1,  0,  0,  1),  // topRight: left + down
            (CGPoint(x: w, y: h), -1,  0,  0, -1),  // bottomRight: left + up
            (CGPoint(x: 0, y: h),  1,  0,  0, -1),  // bottomLeft: right + up
        ]
        for (pt, dx1, dy1, dx2, dy2) in corners {
            var path = Path()
            path.move(to: CGPoint(x: pt.x + dx1 * arm, y: pt.y + dy1 * arm))
            path.addLine(to: pt)
            path.addLine(to: CGPoint(x: pt.x + dx2 * arm, y: pt.y + dy2 * arm))
            strokeOutlined(path, in: &context)
        }
    }

    private static func drawResizeSideTicks(
        w: CGFloat, h: CGFloat,
        in context: inout GraphicsContext
    ) {
        let tick: CGFloat = 6
        // Side ticks: short perpendicular bars crossing each edge midpoint.
        let ticks: [(CGPoint, CGFloat, CGFloat)] = [
            // (midpoint, dx, dy) — tick extends ±(dx,dy) from midpoint
            (CGPoint(x: w / 2, y: 0), 0, tick / 2),    // top: vertical tick
            (CGPoint(x: w / 2, y: h), 0, tick / 2),    // bottom: vertical tick
            (CGPoint(x: 0, y: h / 2), tick / 2, 0),    // left: horizontal tick
            (CGPoint(x: w, y: h / 2), tick / 2, 0),    // right: horizontal tick
        ]
        for (pt, dx, dy) in ticks {
            var path = Path()
            path.move(to: CGPoint(x: pt.x - dx, y: pt.y - dy))
            path.addLine(to: CGPoint(x: pt.x + dx, y: pt.y + dy))
            strokeOutlined(path, in: &context)
        }
    }

    // MARK: - Rotate Handles (quarter-circle arcs at each corner)

    private static func drawRotateCorners(
        w: CGFloat, h: CGFloat, radius: CGFloat,
        in context: inout GraphicsContext
    ) {
        // Each corner: a quarter-circle arc curving outside the bounding box.
        // Same shape as the resize L-brackets but with a rounded 90° corner.
        //
        // Screen coordinates: 0°=right, 90°=down, 180°=left, 270°=up.
        // clockwise: false in SwiftUI = clockwise on screen.
        let inset: CGFloat = 3
        let arcs: [(center: CGPoint, start: Double, end: Double)] = [
            (CGPoint(x: inset,     y: inset),     180, 270),  // topLeft
            (CGPoint(x: w - inset, y: inset),     270, 360),  // topRight
            (CGPoint(x: w - inset, y: h - inset),   0,  90),  // bottomRight
            (CGPoint(x: inset,     y: h - inset),  90, 180),  // bottomLeft
        ]
        for (center, startDeg, endDeg) in arcs {
            var arc = Path()
            arc.addArc(
                center: center, radius: radius,
                startAngle: .degrees(startDeg), endAngle: .degrees(endDeg),
                clockwise: false
            )
            strokeOutlined(arc, in: &context)
        }
    }

    /// Draws a path with a white foreground stroke and accent outline for contrast.
    private static func strokeOutlined(_ path: Path, in context: inout GraphicsContext) {
        let outline = StrokeStyle(
            lineWidth: RenderConstants.handleOutlineWidth,
            lineCap: .round, lineJoin: .round
        )
        let fill = StrokeStyle(
            lineWidth: RenderConstants.handleLineWidth,
            lineCap: .round, lineJoin: .round
        )
        context.stroke(path, with: .color(.accentColor), style: outline)
        context.stroke(path, with: .color(.white), style: fill)
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
