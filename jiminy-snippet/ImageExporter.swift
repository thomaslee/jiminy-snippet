//
//  ImageExporter.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import AppKit
import SwiftUI

struct ImageExporter {

    static func render(
        image: NSImage,
        arrows: [ArrowAnnotation],
        texts: [TextAnnotation]
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

    static func save(image: NSImage, to url: URL) -> Bool {
        guard let pngData = pngData(from: image) else { return false }
        do {
            try pngData.write(to: url)
            return true
        } catch {
            print("Failed to write PNG: \(error)")
            return false
        }
    }

    @discardableResult
    static func copyToPasteboard(image: NSImage) -> Bool {
        guard let pngData = pngData(from: image) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(pngData, forType: .png)
        return true
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

    private static func drawTexts(_ texts: [TextAnnotation], in context: CGContext) {
        for annotation in texts where !annotation.text.isEmpty {
            let font = RenderConstants.textFont(size: annotation.fontSize)
            let outlineColor = NSColor(
                AnnotationRenderer.arrowOutlineColor(for: annotation.color)
            )

            // `.strokeWidth` is a percentage of the font point size and is
            // center-aligned on each glyph edge, so the visible outline is
            // half the total stroke. A negative value both fills and strokes.
            let visibleRadius = AnnotationRenderer.textOutlineRadius(for: annotation.fontSize)
            let strokeWidth = -(2 * visibleRadius / annotation.fontSize * 100)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(annotation.color),
                .strokeColor: outlineColor,
                .strokeWidth: strokeWidth,
            ]
            let string = NSAttributedString(string: annotation.text, attributes: attrs)

            context.saveGState()
            context.translateBy(x: annotation.position.x, y: annotation.position.y)
            context.rotate(by: annotation.rotation * .pi / 180)
            context.scaleBy(x: annotation.scaleX, y: annotation.scaleY)
            let origin = CGPoint(
                x: RenderConstants.textPaddingH,
                y: RenderConstants.textPaddingV
            )
            string.draw(at: origin)
            context.restoreGState()
        }
    }
}
