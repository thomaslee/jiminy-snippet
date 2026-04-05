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
            drawTexts(texts, in: context)
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
            let cgPath = AnnotationRenderer.arrowPath(start: arrow.start, end: arrow.end).cgPath
            context.setStrokeColor(NSColor(arrow.color).cgColor)
            context.setLineWidth(arrow.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(cgPath)
            context.strokePath()
        }
    }

    private static func drawTexts(_ texts: [TextAnnotation], in context: CGContext) {
        for annotation in texts where !annotation.text.isEmpty {
            let font = NSFont.boldSystemFont(ofSize: annotation.fontSize)

            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 1, height: -1)
            shadow.shadowBlurRadius = 1
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(annotation.color),
                .shadow: shadow,
            ]
            let string = NSAttributedString(string: annotation.text, attributes: attrs)

            context.saveGState()
            context.translateBy(x: annotation.position.x, y: annotation.position.y)
            context.rotate(by: -annotation.rotation * .pi / 180)
            string.draw(at: .zero)
            context.restoreGState()
        }
    }
}
