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
        rotation: Double,
        includeAnnotations: Bool
    ) -> NSImage? {
        let imageSize = image.size

        // Calculate output size accounting for rotation
        let normalizedRotation = ((Int(rotation) % 360) + 360) % 360
        let isRotated90 = normalizedRotation == 90 || normalizedRotation == 270
        let outputSize = isRotated90
            ? NSSize(width: imageSize.height, height: imageSize.width)
            : imageSize

        let outputImage = NSImage(size: outputSize)
        outputImage.lockFocusFlipped(true)

        guard let context = NSGraphicsContext.current?.cgContext else {
            outputImage.unlockFocus()
            return nil
        }

        // Rotate around center
        context.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
        context.rotate(by: -rotation * .pi / 180) // negative because CG Y is flipped
        context.translateBy(x: -imageSize.width / 2, y: -imageSize.height / 2)

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
            let nsColor = NSColor(arrow.color)
            nsColor.setStroke()

            let path = NSBezierPath()
            path.lineWidth = arrow.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Shaft
            path.move(to: NSPoint(x: arrow.start.x, y: arrow.start.y))
            path.line(to: NSPoint(x: arrow.end.x, y: arrow.end.y))
            path.stroke()

            // Arrowhead
            let dx = arrow.end.x - arrow.start.x
            let dy = arrow.end.y - arrow.start.y
            let length = sqrt(dx * dx + dy * dy)
            guard length > 0 else { continue }

            let angle = atan2(dy, dx)
            let headLength = min(20, length * 0.3)
            let headAngle: CGFloat = .pi / 6

            let p1 = NSPoint(
                x: arrow.end.x - headLength * cos(angle - headAngle),
                y: arrow.end.y - headLength * sin(angle - headAngle)
            )
            let p2 = NSPoint(
                x: arrow.end.x - headLength * cos(angle + headAngle),
                y: arrow.end.y - headLength * sin(angle + headAngle)
            )

            let headPath = NSBezierPath()
            headPath.lineWidth = arrow.lineWidth
            headPath.lineCapStyle = .round
            headPath.lineJoinStyle = .round
            headPath.move(to: p1)
            headPath.line(to: NSPoint(x: arrow.end.x, y: arrow.end.y))
            headPath.line(to: p2)
            headPath.stroke()
        }
    }

    private static func drawTexts(_ texts: [TextAnnotation]) {
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
            string.draw(at: NSPoint(x: text.position.x, y: text.position.y))
        }
    }
}
