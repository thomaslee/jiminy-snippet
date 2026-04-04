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
    static let selectionPadding: CGFloat = 4
    static let textPaddingH: CGFloat = 4
    static let textPaddingV: CGFloat = 2
}

/// Draws annotations into a SwiftUI `GraphicsContext` (used by Canvas).
enum AnnotationRenderer {

    // MARK: - Arrow Drawing

    static func drawArrow(_ arrow: ArrowAnnotation, in context: inout GraphicsContext) {
        let path = arrowPath(start: arrow.start, end: arrow.end)
        context.stroke(
            path,
            with: .color(arrow.color),
            style: StrokeStyle(lineWidth: arrow.lineWidth, lineCap: .round, lineJoin: .round)
        )
    }

    static func drawArrowSelection(_ arrow: ArrowAnnotation, in context: inout GraphicsContext) {
        let path = arrowPath(start: arrow.start, end: arrow.end)
        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.4)),
            style: StrokeStyle(lineWidth: arrow.lineWidth + 8, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Text Drawing

    static func drawText(_ annotation: TextAnnotation, in context: inout GraphicsContext) {
        let text = Text(annotation.text.isEmpty ? " " : annotation.text)
            .font(.system(size: annotation.fontSize, weight: .bold))
            .foregroundStyle(annotation.color)

        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))

        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))
            ctx.addFilter(.shadow(color: .black.opacity(0.5), radius: 1, x: 1, y: 1))
            let origin = CGPoint(x: RenderConstants.textPaddingH, y: RenderConstants.textPaddingV)
            ctx.draw(resolved, in: CGRect(origin: origin, size: size))
        }
    }

    static func drawTextSelection(
        _ annotation: TextAnnotation,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        let localRect = CGRect(
            origin: .zero,
            size: CGSize(
                width: size.width + RenderConstants.textPaddingH * 2,
                height: size.height + RenderConstants.textPaddingV * 2
            )
        )
        context.drawLayer { ctx in
            ctx.translateBy(x: annotation.position.x, y: annotation.position.y)
            ctx.rotate(by: .degrees(annotation.rotation))
            let path = Path(roundedRect: localRect, cornerRadius: 4)
            ctx.stroke(path, with: .color(.accentColor), lineWidth: 2)
        }
    }

    // MARK: - Handles

    static func drawEndpointHandle(at point: CGPoint, in context: inout GraphicsContext) {
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

    static func drawResizeHandle(at point: CGPoint, in context: inout GraphicsContext) {
        drawEndpointHandle(at: point, in: &context)
    }

    // MARK: - Text Measurement

    static func measureText(
        _ annotation: TextAnnotation,
        in context: GraphicsContext
    ) -> CGSize {
        let text = Text(annotation.text.isEmpty ? " " : annotation.text)
            .font(.system(size: annotation.fontSize, weight: .bold))
        let resolved = context.resolve(text)
        return resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
    }

    /// Measures text without needing a GraphicsContext (for hit testing).
    static func measureText(_ annotation: TextAnnotation) -> CGSize {
        let font = NSFont.boldSystemFont(ofSize: annotation.fontSize)
        let string = annotation.text.isEmpty ? " " : annotation.text
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return NSAttributedString(string: string, attributes: attrs).size()
    }

    // MARK: - Geometry Helpers

    /// Bounding rect for a text annotation including padding.
    static func textBoundingRect(for annotation: TextAnnotation, measuredSize: CGSize) -> CGRect {
        CGRect(
            x: annotation.position.x,
            y: annotation.position.y,
            width: measuredSize.width + RenderConstants.textPaddingH * 2,
            height: measuredSize.height + RenderConstants.textPaddingV * 2
        )
    }

    /// Bottom-trailing corner point for the resize handle, in canvas coordinates.
    static func resizeHandlePoint(for annotation: TextAnnotation, measuredSize: CGSize) -> CGPoint {
        let localX = measuredSize.width + RenderConstants.textPaddingH * 2 + RenderConstants.handleSize / 2
        let localY = measuredSize.height + RenderConstants.textPaddingV * 2 + RenderConstants.handleSize / 2
        return rotateLocalPoint(CGPoint(x: localX, y: localY), around: annotation.position, angle: annotation.rotation)
    }

    /// Transforms a point from a text annotation's local coordinate space to canvas coordinates.
    static func rotateLocalPoint(_ local: CGPoint, around origin: CGPoint, angle: Double) -> CGPoint {
        let rad = angle * .pi / 180
        let cosA = cos(rad)
        let sinA = sin(rad)
        return CGPoint(
            x: origin.x + local.x * cosA - local.y * sinA,
            y: origin.y + local.x * sinA + local.y * cosA
        )
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
}
