//
//  Annotation.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

enum AnnotationTool: String, CaseIterable {
    case arrow = "Arrow"
    case text = "Text"
    case rectangle = "Rectangle"

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        }
    }

    var helpText: String {
        switch self {
        case .arrow: "Draw an arrow"
        case .text: "Add a text label"
        case .rectangle: "Draw a rectangle"
        }
    }
}

/// Whether a rectangle annotation renders as an outline or a solid fill.
enum RectangleFillStyle: String, CaseIterable, Equatable {
    case outlined
    case filled
}

struct ArrowAnnotation: Identifiable, Equatable {
    static let defaultLineWidth: CGFloat = 4

    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var lineWidth: CGFloat = ArrowAnnotation.defaultLineWidth

    /// Returns a copy with a fresh id and both endpoints shifted by `offset`,
    /// so the duplicate is visually distinguishable from the original.
    func duplicated(offset: CGSize) -> ArrowAnnotation {
        ArrowAnnotation(
            start: CGPoint(x: start.x + offset.width, y: start.y + offset.height),
            end: CGPoint(x: end.x + offset.width, y: end.y + offset.height),
            color: color,
            lineWidth: lineWidth
        )
    }
}

struct RectangleAnnotation: Identifiable, Equatable {
    static let defaultLineWidth: CGFloat = 4

    let id = UUID()
    /// May be non-standardized during an in-flight drag (negative width/height
    /// if the user dragged past the opposite edge). Hit testing and rendering
    /// both call `.standardized` so this is safe to store as-is.
    var rect: CGRect
    var color: Color
    var lineWidth: CGFloat = RectangleAnnotation.defaultLineWidth
    var style: RectangleFillStyle

    /// Returns a copy with a fresh id and the rect shifted by `offset`, so the
    /// duplicate is visually distinguishable from the original.
    func duplicated(offset: CGSize) -> RectangleAnnotation {
        RectangleAnnotation(
            rect: rect.offsetBy(dx: offset.width, dy: offset.height),
            color: color,
            lineWidth: lineWidth,
            style: style
        )
    }
}

struct TextAnnotation: Identifiable, Equatable {
    let id = UUID()
    var position: CGPoint
    var text: String
    var color: Color
    var fontSize: CGFloat = 24
    var rotation: Double = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    /// Returns a copy with a fresh id and position shifted by `offset`,
    /// so the duplicate is visually distinguishable from the original.
    func duplicated(offset: CGSize) -> TextAnnotation {
        TextAnnotation(
            position: CGPoint(x: position.x + offset.width, y: position.y + offset.height),
            text: text,
            color: color,
            fontSize: fontSize,
            rotation: rotation,
            scaleX: scaleX,
            scaleY: scaleY
        )
    }
}

extension NSImage {
    /// Returns a new image cropped to `rect` (expressed in the image's point space).
    /// Preserves the full pixel resolution of the source bitmap.
    func cropped(to rect: CGRect) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let sx = CGFloat(cgImage.width) / pointSize.width
        let sy = CGFloat(cgImage.height) / pointSize.height
        let pixelRect = CGRect(
            x: rect.origin.x * sx,
            y: rect.origin.y * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral

        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let croppedCG = cgImage.cropping(to: pixelRect)
        else {
            return nil
        }

        let newPointSize = CGSize(
            width: pixelRect.width / sx,
            height: pixelRect.height / sy
        )
        return NSImage(cgImage: croppedCG, size: newPointSize)
    }

    /// Returns a new image scaled to `newSize` (in points). Uses the same
    /// drawing approach as `rotated(clockwise:)` so it works reliably with
    /// any source bitmap representation.
    func resized(to newSize: NSSize) -> NSImage? {
        guard newSize.width >= 1, newSize.height >= 1 else { return nil }
        let originalSize = size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }

        return NSImage(size: newSize, flipped: false) { _ in
            self.draw(
                in: NSRect(origin: .zero, size: newSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            return true
        }
    }

    /// Returns a new image rotated by 90° with swapped dimensions.
    func rotated(clockwise: Bool) -> NSImage {
        let originalSize = size
        let newSize = NSSize(width: originalSize.height, height: originalSize.width)
        return NSImage(size: newSize, flipped: false) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
            transform.rotate(byDegrees: clockwise ? -90 : 90)
            transform.translateX(by: -originalSize.width / 2, yBy: -originalSize.height / 2)
            transform.concat()
            self.draw(
                in: NSRect(origin: .zero, size: originalSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            return true
        }
    }
}

enum AnnotationPalette {
    static let colors: [(name: String, color: Color)] = [
        ("Pink", Color(red: 0.95, green: 0.15, blue: 0.45)),
        ("Orange", Color(red: 1.0, green: 0.6, blue: 0.0)),
        ("Red", Color.red),
        ("Yellow", Color.yellow),
        ("Green", Color.green),
        ("Blue", Color.blue),
        ("Purple", Color.purple),
        ("White", Color.white),
        ("Black", Color.black),
    ]
}
