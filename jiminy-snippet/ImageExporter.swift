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
        texts: [TextAnnotation],
        includeAnnotations: Bool
    ) -> NSImage? {
        let imageSize = image.size

        let outputImage = NSImage(size: imageSize)
        outputImage.lockFocusFlipped(true)

        guard let context = NSGraphicsContext.current?.cgContext else {
            outputImage.unlockFocus()
            return nil
        }

        // NSImage.draw auto-flips in a flipped context, producing an inverted result.
        // Temporarily flip the coordinate system back for the image draw.
        context.saveGState()
        context.translateBy(x: 0, y: imageSize.height)
        context.scaleBy(x: 1, y: -1)
        image.draw(
            in: NSRect(origin: .zero, size: imageSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        context.restoreGState()

        if includeAnnotations {
            drawArrows(arrows, in: context)
            drawTexts(texts)
        }

        outputImage.unlockFocus()
        return outputImage
    }

    static func save(image: NSImage, to url: URL) -> Bool {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return false
        }
        do {
            try pngData.write(to: url)
            return true
        } catch {
            print("Failed to write PNG: \(error)")
            return false
        }
    }

    // MARK: - Private

    private static func drawArrows(_ arrows: [ArrowAnnotation], in context: CGContext) {
        for arrow in arrows {
            NSColor(arrow.color).setStroke()

            let path = NSBezierPath()
            path.lineWidth = arrow.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: arrow.start.x, y: arrow.start.y))
            path.line(to: NSPoint(x: arrow.end.x, y: arrow.end.y))
            path.stroke()

            if let wings = arrowHeadWings(tip: arrow.end, tail: arrow.start) {
                let headPath = NSBezierPath()
                headPath.lineWidth = arrow.lineWidth
                headPath.lineCapStyle = .round
                headPath.lineJoinStyle = .round
                headPath.move(to: NSPoint(x: wings.left.x, y: wings.left.y))
                headPath.line(to: NSPoint(x: arrow.end.x, y: arrow.end.y))
                headPath.line(to: NSPoint(x: wings.right.x, y: wings.right.y))
                headPath.stroke()
            }
        }
    }

    private static func drawTexts(_ texts: [TextAnnotation]) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for text in texts where !text.text.isEmpty {
            let nsColor = NSColor(text.color)
            let font = NSFont.boldSystemFont(ofSize: text.fontSize)

            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 1
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: nsColor,
                .shadow: shadow,
            ]
            let string = NSAttributedString(string: text.text, attributes: attrs)

            context.saveGState()
            context.translateBy(x: text.position.x, y: text.position.y)
            context.rotate(by: -text.rotation * .pi / 180)
            string.draw(at: .zero)
            context.restoreGState()
        }
    }
}
