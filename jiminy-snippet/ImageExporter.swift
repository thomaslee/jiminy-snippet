//
//  ImageExporter.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import AppKit
import SwiftUI

enum ImageExportError: LocalizedError {
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .pngEncodingFailed:
            return "Could not encode the image as PNG."
        }
    }
}

struct ImageExporter {

    static func render(
        image: NSImage,
        arrows: [ArrowAnnotation],
        texts: [TextAnnotation],
        rectangles: [RectangleAnnotation]
    ) -> NSImage {
        let pointSize = image.size
        let pixelSize = pixelSize(of: image) ?? pointSize

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                  data: nil,
                  width: Int(pixelSize.width),
                  height: Int(pixelSize.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return image
        }

        // Draw the source image at full pixel resolution.
        context.draw(cgImage, in: CGRect(origin: .zero, size: pixelSize))

        // Switch to a flipped (top-left origin) point-space coordinate system
        // so annotations authored in SwiftUI point-space render correctly and
        // at the bitmap's full pixel resolution.
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(
            x: pixelSize.width / pointSize.width,
            y: -pixelSize.height / pointSize.height
        )

        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        drawArrows(arrows, in: context)
        drawRectangles(rectangles, in: context)
        drawTexts(texts, in: context)

        NSGraphicsContext.restoreGraphicsState()

        guard let outputCGImage = context.makeImage() else {
            return image
        }
        return NSImage(cgImage: outputCGImage, size: pointSize)
    }

    private static func pixelSize(of image: NSImage) -> CGSize? {
        var maxW = 0
        var maxH = 0
        for rep in image.representations {
            maxW = max(maxW, rep.pixelsWide)
            maxH = max(maxH, rep.pixelsHigh)
        }
        guard maxW > 0, maxH > 0 else { return nil }
        return CGSize(width: maxW, height: maxH)
    }

    static func save(image: NSImage, to url: URL) throws {
        guard let pngData = pngData(from: image) else {
            throw ImageExportError.pngEncodingFailed
        }
        try pngData.write(to: url)
    }

    @discardableResult
    static func copyToPasteboard(image: NSImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Private

    private static func drawArrows(_ arrows: [ArrowAnnotation], in context: CGContext) {
        for arrow in arrows {
            let cgPath = AnnotationRenderer.arrowPath(
                start: arrow.start, end: arrow.end, lineWidth: arrow.lineWidth
            ).cgPath
            let outlineColor = NSColor(AnnotationRenderer.arrowOutlineColor(for: arrow.color)).cgColor
            let outlineWidth = AnnotationRenderer.arrowOutlineWidth(for: arrow.lineWidth)

            context.saveGState()
            context.addPath(cgPath)
            context.setFillColor(NSColor(arrow.color).cgColor)
            context.fillPath()

            context.addPath(cgPath)
            context.setStrokeColor(outlineColor)
            context.setLineWidth(outlineWidth)
            context.setLineJoin(.miter)
            context.setMiterLimit(6)
            context.strokePath()
            context.restoreGState()
        }
    }

    private static func drawRectangles(_ rectangles: [RectangleAnnotation], in context: CGContext) {
        for rectangle in rectangles {
            let bounds = rectangle.rect.standardized
            guard bounds.width > 0, bounds.height > 0 else { continue }

            let fillColor = NSColor(rectangle.color).cgColor
            let outlineColor = NSColor(
                AnnotationRenderer.arrowOutlineColor(for: rectangle.color)
            ).cgColor
            let outlineWidth = AnnotationRenderer.arrowOutlineWidth(for: rectangle.lineWidth)

            context.saveGState()
            context.setLineJoin(.miter)

            switch rectangle.style {
            case .filled:
                context.setFillColor(fillColor)
                context.fill(bounds)
                context.setStrokeColor(outlineColor)
                context.setLineWidth(outlineWidth)
                context.stroke(bounds)
            case .outlined:
                let strokeW = rectangle.lineWidth * 2.5
                context.setStrokeColor(outlineColor)
                context.setLineWidth(strokeW + outlineWidth * 2)
                context.stroke(bounds)
                context.setStrokeColor(fillColor)
                context.setLineWidth(strokeW)
                context.stroke(bounds)
            }

            context.restoreGState()
        }
    }

    private static func drawTexts(_ texts: [TextAnnotation], in context: CGContext) {
        for annotation in texts where !annotation.text.isEmpty {
            let font = RenderConstants.textFont(size: annotation.fontSize)

            // Resolve SwiftUI Colors to concrete sRGB NSColors up-front. The
            // export CGContext has no NSAppearance, so dynamic colors bridged
            // from SwiftUI can otherwise resolve unpredictably.
            let foregroundColor = NSColor(annotation.color).usingColorSpace(.sRGB)
                ?? NSColor(annotation.color)
            let outlineColor = NSColor(
                AnnotationRenderer.arrowOutlineColor(for: annotation.color)
            ).usingColorSpace(.sRGB) ?? .black

            let fillString = NSAttributedString(
                string: annotation.text,
                attributes: [.font: font, .foregroundColor: foregroundColor]
            )
            let outlineString = NSAttributedString(
                string: annotation.text,
                attributes: [.font: font, .foregroundColor: outlineColor]
            )

            // Match the on-screen renderer: stamp the outline-colored text at
            // eight points on a circle around the origin to fake a border,
            // then draw the real fill on top. Using `.strokeWidth` on the
            // attributed string looks correct on screen but produces a black
            // glyph in this headless CGContext.
            let radius = AnnotationRenderer.textOutlineRadius(for: annotation.fontSize)
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

            context.saveGState()
            context.translateBy(x: annotation.position.x, y: annotation.position.y)
            context.rotate(by: annotation.rotation * .pi / 180)
            context.scaleBy(x: annotation.scaleX, y: annotation.scaleY)
            let origin = CGPoint(
                x: RenderConstants.textPaddingH,
                y: RenderConstants.textPaddingV
            )
            for (dx, dy) in offsets {
                outlineString.draw(at: CGPoint(x: origin.x + dx, y: origin.y + dy))
            }
            fillString.draw(at: origin)
            context.restoreGState()
        }
    }
}
