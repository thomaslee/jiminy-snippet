//
//  Annotation.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum AnnotationTool: String, CaseIterable {
    case arrow = "Arrow"
    case text = "Text"
    case rectangle = "Rectangle"
    case pixelate = "Pixelate"

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .pixelate: "square.grid.3x3.fill"
        }
    }

    var helpText: String {
        switch self {
        case .arrow: "Draw an arrow"
        case .text: "Add a text label"
        case .rectangle: "Draw a rectangle"
        case .pixelate: "Pixelate a region (permanent — redacts the image)"
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
    /// Rotation in degrees, applied around the rect's visual center. The
    /// stored `rect` always describes the unrotated bounds.
    var rotation: Double = 0

    /// Returns a copy with a fresh id and the rect shifted by `offset`, so the
    /// duplicate is visually distinguishable from the original.
    func duplicated(offset: CGSize) -> RectangleAnnotation {
        RectangleAnnotation(
            rect: rect.offsetBy(dx: offset.width, dy: offset.height),
            color: color,
            lineWidth: lineWidth,
            style: style,
            rotation: rotation
        )
    }
}

/// Defaults shared by the destructive pixelate tool. Pixelation is applied
/// directly to the bitmap (not stored as an annotation) so a redacted region
/// can't be moved, deleted, or otherwise un-hidden by accident.
enum PixelateDefaults {
    /// Block size in points. Tuned to be aggressive enough that small text
    /// (e.g. a 12pt token) is unrecoverable on a Retina display.
    static let blockSize: CGFloat = 28
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

    /// Returns a copy of this image with `CIPixellate` applied, producing
    /// chunky square blocks of `blockSize` points. Preserves the bitmap's
    /// pixel resolution so the result remains crisp on Retina. Returns nil
    /// when the image has no rasterizable representation.
    func pixelated(blockSize: CGFloat) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelsPerPoint = CGFloat(cgImage.width) / pointSize.width
        let filter = CIFilter.pixellate()
        let ciImage = CIImage(cgImage: cgImage)
        filter.inputImage = ciImage
        // CIPixellate's `scale` is in pixels — scale up to match Retina assets.
        filter.scale = Float(max(1, blockSize * pixelsPerPoint))
        // Anchor at the image's top-left corner so blocks start cleanly at
        // the edge instead of being phase-shifted by the filter's default
        // center anchor.
        filter.center = CGPoint(x: 0, y: 0)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = filter.outputImage,
              let rendered = context.createCGImage(output, from: ciImage.extent)
        else {
            return nil
        }
        return NSImage(cgImage: rendered, size: pointSize)
    }

    /// Returns a copy of this image with the given canvas-point rect replaced
    /// by a pixelated version of the underlying pixels. The rest of the
    /// bitmap is untouched. Used by the destructive pixelate tool — once
    /// applied, only an explicit Undo can recover the original pixels.
    func pixelating(rect: CGRect, blockSize: CGFloat) -> NSImage? {
        guard let originalCG = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let pixelatedNS = pixelated(blockSize: blockSize),
              let pixelatedCG = pixelatedNS.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelW = CGFloat(originalCG.width)
        let pixelH = CGFloat(originalCG.height)
        let sx = pixelW / pointSize.width
        let sy = pixelH / pointSize.height

        // Convert the canvas-point rect (top-left origin) into the CGContext's
        // bottom-left-origin pixel space.
        let pixelRect = CGRect(
            x: rect.minX * sx,
            y: pixelH - rect.maxY * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return self }

        guard let context = CGContext(
            data: nil,
            width: Int(pixelW),
            height: Int(pixelH),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let fullPixelRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)
        context.draw(originalCG, in: fullPixelRect)

        // Stamp the pre-pixelated full image, clipped to the target rect, on
        // top of the original. Same source coordinate system for both, so
        // pixels line up.
        context.saveGState()
        context.clip(to: pixelRect)
        context.draw(pixelatedCG, in: fullPixelRect)
        context.restoreGState()

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: pointSize)
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
