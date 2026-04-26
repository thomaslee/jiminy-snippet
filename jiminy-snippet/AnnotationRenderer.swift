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

    /// Chunky square selection handles — filled white with a thick accent
    /// border. Sized to read clearly without dominating small annotations.
    static let squareHandleSize: CGFloat = 11
    static let squareHandleBorder: CGFloat = 2
    static let squareHandleCornerRadius: CGFloat = 1.5

    /// Pale-blue circular rotation handle. Slightly larger than the squares
    /// because circles read smaller at equal pixel dimensions.
    static let rotateHandleSize: CGFloat = 13

    /// Distance from the top-center handle to the rotation handle, measured
    /// in the annotation's local (pre-rotation) space.
    static let rotateHandleOffset: CGFloat = 22

    /// Width of the pale connector line drawn between the rotation handle
    /// and the top-center resize handle.
    static let handleConnectorWidth: CGFloat = 1.5

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
        drawCartoonArrow(
            start: arrow.start,
            end: arrow.end,
            color: arrow.color,
            lineWidth: arrow.lineWidth,
            selected: selected,
            in: &context
        )

        if selected {
            drawHandle(at: arrow.start, in: &context)
            drawHandle(at: arrow.end, in: &context)
        }
    }

    /// Draws a chunky, stylized "sticker" arrow: a filled polygon with a
    /// contrasting outline. Used for both committed annotations and the
    /// in-progress drag preview.
    static func drawCartoonArrow(
        start: CGPoint,
        end: CGPoint,
        color: Color,
        lineWidth: CGFloat,
        selected: Bool,
        in context: inout GraphicsContext
    ) {
        let path = arrowPath(start: start, end: end, lineWidth: lineWidth)
        guard !path.isEmpty else { return }

        if selected {
            context.stroke(
                path,
                with: .color(.accentColor.opacity(0.4)),
                style: StrokeStyle(lineWidth: arrowOutlineWidth(for: lineWidth) + 8, lineJoin: .round)
            )
        }

        context.fill(path, with: .color(color))
        context.stroke(
            path,
            with: .color(arrowOutlineColor(for: color)),
            style: StrokeStyle(
                lineWidth: arrowOutlineWidth(for: lineWidth),
                lineJoin: .miter,
                miterLimit: 6
            )
        )
    }

    /// Width of the dark/light outline stroked around the arrow fill.
    static func arrowOutlineWidth(for lineWidth: CGFloat) -> CGFloat {
        max(1.5, lineWidth * 0.6)
    }

    /// Chooses a contrasting outline color for an arrow fill color so the
    /// arrow reads crisply over any background — white for dark fills,
    /// near-black for bright fills.
    static func arrowOutlineColor(for color: Color) -> Color {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let luminance = 0.299 * resolved.redComponent
                      + 0.587 * resolved.greenComponent
                      + 0.114 * resolved.blueComponent
        return luminance < 0.3
            ? Color.white
            : Color(red: 0.12, green: 0.12, blue: 0.16)
    }

    // MARK: - Rectangle Drawing

    /// Draws a rectangle annotation with optional selection chrome. Outlined
    /// rectangles use a chunky double-stroke (contrast outline + color fill
    /// stroke) that matches the arrow body's visual weight; filled rectangles
    /// fill the interior and stroke a thin contrast border around the edge.
    /// Rotation is applied around the rect's visual center.
    static func drawRectangle(
        _ rectangle: RectangleAnnotation,
        selected: Bool,
        in context: inout GraphicsContext
    ) {
        let bounds = rectangle.rect.standardized
        guard bounds.width > 0, bounds.height > 0 else { return }

        let outlineColor = arrowOutlineColor(for: rectangle.color)
        let outlineW = arrowOutlineWidth(for: rectangle.lineWidth)
        let w = bounds.width
        let h = bounds.height
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let localRect = CGRect(x: 0, y: 0, width: w, height: h)
        let path = Path(localRect)

        context.drawLayer { ctx in
            // Pivot around the rect's visual center so rotation feels natural.
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: .degrees(rectangle.rotation))
            ctx.translateBy(x: -w / 2, y: -h / 2)

            if selected {
                // Accent-color glow, drawn first so it sits behind the body.
                let totalVisible: CGFloat
                switch rectangle.style {
                case .outlined:
                    totalVisible = rectangle.lineWidth * 2.5 + outlineW * 2
                case .filled:
                    totalVisible = outlineW
                }
                ctx.stroke(
                    path,
                    with: .color(.accentColor.opacity(0.4)),
                    style: StrokeStyle(lineWidth: totalVisible + 8, lineJoin: .miter)
                )
            }

            switch rectangle.style {
            case .outlined:
                let strokeW = rectangle.lineWidth * 2.5
                ctx.stroke(
                    path,
                    with: .color(outlineColor),
                    style: StrokeStyle(lineWidth: strokeW + outlineW * 2, lineJoin: .miter)
                )
                ctx.stroke(
                    path,
                    with: .color(rectangle.color),
                    style: StrokeStyle(lineWidth: strokeW, lineJoin: .miter)
                )
            case .filled:
                ctx.fill(path, with: .color(rectangle.color))
                ctx.stroke(
                    path,
                    with: .color(outlineColor),
                    style: StrokeStyle(lineWidth: outlineW, lineJoin: .miter)
                )
            }

            if selected {
                ctx.stroke(
                    Path(roundedRect: localRect, cornerRadius: 4),
                    with: .color(.accentColor.opacity(0.7)), lineWidth: 1.5
                )
                drawRotateConnector(w: w, in: &ctx)
                drawSquareHandles(w: w, h: h, in: &ctx)
                drawRotateHandle(at: rotateHandleLocalPoint(w: w), in: &ctx)
            }
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
    /// The text is rendered with a contrasting cartoon-style outline that
    /// matches the arrow-annotation outline aesthetic.
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

            let origin = CGPoint(x: RenderConstants.textPaddingH, y: RenderConstants.textPaddingV)
            let radius = textOutlineRadius(for: annotation.fontSize)

            // SwiftUI Canvas can't stroke glyphs directly, so stamp a dark
            // copy of the text at eight points on a circle around the origin
            // to fake an outline, then draw the real fill on top.
            let outlineText = Text(annotation.text.isEmpty ? " " : annotation.text)
                .font(.system(size: annotation.fontSize, weight: .bold))
                .foregroundStyle(arrowOutlineColor(for: annotation.color))
            let resolvedOutline = ctx.resolve(outlineText)

            let diag = radius * 0.7071
            let offsets: [(CGFloat, CGFloat)] = [
                ( radius,      0),
                ( diag,     diag),
                (     0,  radius),
                (-diag,     diag),
                (-radius,      0),
                (-diag,    -diag),
                (     0, -radius),
                ( diag,    -diag),
            ]
            for (dx, dy) in offsets {
                let p = CGPoint(x: origin.x + dx, y: origin.y + dy)
                ctx.draw(resolvedOutline, in: CGRect(origin: p, size: size))
            }

            ctx.draw(resolved, in: CGRect(origin: origin, size: size))
        }
    }

    /// Visible outline thickness around text glyphs, in points. Scales
    /// gently with font size so larger text gets a proportionally chunkier
    /// border.
    static func textOutlineRadius(for fontSize: CGFloat) -> CGFloat {
        max(1.5, fontSize * 0.08)
    }

    /// Draws selection chrome and handles for a text annotation: a thin
    /// selection rectangle, eight chunky square resize handles, and a
    /// dedicated rotation handle floating above the top edge — connected to
    /// the top-center handle by a pale accent line so the rotation affordance
    /// reads as part of the same selection chrome.
    static func drawTextSelection(
        _ annotation: TextAnnotation,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        let padded = RenderConstants.paddedTextSize(size)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )

        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))

            let rect = CGRect(origin: .zero, size: scaledSize)
            ctx.stroke(
                Path(roundedRect: rect, cornerRadius: 4),
                with: .color(.accentColor.opacity(0.7)), lineWidth: 1.5
            )

            drawRotateConnector(w: scaledSize.width, in: &ctx)
            drawSquareHandles(w: scaledSize.width, h: scaledSize.height, in: &ctx)
            drawRotateHandle(at: rotateHandleLocalPoint(w: scaledSize.width), in: &ctx)
        }
    }

    /// Local-space position of the dedicated rotation handle, sitting above
    /// the top-center resize handle.
    static func rotateHandleLocalPoint(w: CGFloat) -> CGPoint {
        CGPoint(x: w / 2, y: -RenderConstants.rotateHandleOffset)
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

    // MARK: - Square Handles

    /// Draws the eight chunky square handles around a w×h bounding box (four
    /// corners + four side midpoints). Local coordinates: caller is expected
    /// to have translated/rotated the context so (0,0) is the box top-left.
    static func drawSquareHandles(
        w: CGFloat, h: CGFloat,
        in context: inout GraphicsContext
    ) {
        let positions: [CGPoint] = [
            CGPoint(x: 0,     y: 0),     CGPoint(x: w / 2, y: 0),     CGPoint(x: w, y: 0),
            CGPoint(x: 0,     y: h / 2),                              CGPoint(x: w, y: h / 2),
            CGPoint(x: 0,     y: h),     CGPoint(x: w / 2, y: h),     CGPoint(x: w, y: h),
        ]
        for pt in positions {
            drawSquareHandle(at: pt, in: &context)
        }
    }

    /// Draws a single chunky square handle centered on `point`: filled white
    /// fill with a thick accent border, slight corner rounding for polish.
    static func drawSquareHandle(at point: CGPoint, in context: inout GraphicsContext) {
        let s = RenderConstants.squareHandleSize
        let rect = CGRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s)
        let path = Path(roundedRect: rect, cornerRadius: RenderConstants.squareHandleCornerRadius)
        context.fill(path, with: .color(.white))
        context.stroke(
            path,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: RenderConstants.squareHandleBorder, lineJoin: .miter)
        )
    }

    /// Pale-blue circular rotation handle. Distinct shape + colour from the
    /// square resize handles so the affordance reads instantly as "spin"
    /// rather than "drag a side".
    static func drawRotateHandle(at point: CGPoint, in context: inout GraphicsContext) {
        let s = RenderConstants.rotateHandleSize
        let rect = CGRect(x: point.x - s / 2, y: point.y - s / 2, width: s, height: s)
        let path = Path(ellipseIn: rect)
        // Pale-blue tint mixed with white, fully opaque so it doesn't blend
        // into whatever sits behind the annotation.
        context.fill(path, with: .color(Color(red: 0.74, green: 0.85, blue: 0.98)))
        context.stroke(
            path,
            with: .color(.accentColor),
            style: StrokeStyle(lineWidth: RenderConstants.squareHandleBorder)
        )
    }

    /// Pale accent line linking the top-center resize handle to the rotation
    /// handle above it, so the two read as a single piece of selection chrome.
    private static func drawRotateConnector(w: CGFloat, in context: inout GraphicsContext) {
        var line = Path()
        line.move(to: CGPoint(x: w / 2, y: 0))
        line.addLine(to: CGPoint(x: w / 2, y: -RenderConstants.rotateHandleOffset))
        context.stroke(
            line,
            with: .color(.accentColor.opacity(0.5)),
            style: StrokeStyle(lineWidth: RenderConstants.handleConnectorWidth, lineCap: .round)
        )
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

    /// Builds a closed filled-polygon `Path` for a cartoony sticker arrow:
    /// a chunky shaft opening into a big triangular head. Proportions scale
    /// with `lineWidth`. Returns an empty path for zero-length arrows.
    static func arrowPath(start: CGPoint, end: CGPoint, lineWidth: CGFloat) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return path }

        // Proportions are tuned for a bold "sticker" look at lineWidth=4.
        let w = lineWidth
        let shaftHalf = w * 1.4                    // shaft thickness ≈ 2.8 × lineWidth
        let headHalf = w * 3.2                     // head width     ≈ 6.4 × lineWidth
        let headLen = min(w * 5.5, length * 0.85)  // clamp so short arrows stay arrow-shaped
        let shaftLen = max(0, length - headLen)

        let cosA = dx / length
        let sinA = dy / length

        // Map a point from arrow-local space (tail at origin, tip along +x)
        // to canvas coordinates.
        func transform(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: start.x + x * cosA - y * sinA,
                y: start.y + x * sinA + y * cosA
            )
        }

        // Polygon vertices, traced around the arrow outline.
        path.move(to: transform(0, -shaftHalf))
        path.addLine(to: transform(shaftLen, -shaftHalf))
        path.addLine(to: transform(shaftLen, -headHalf))
        path.addLine(to: transform(length, 0))
        path.addLine(to: transform(shaftLen, headHalf))
        path.addLine(to: transform(shaftLen, shaftHalf))
        path.addLine(to: transform(0, shaftHalf))
        path.closeSubpath()
        return path
    }
}
