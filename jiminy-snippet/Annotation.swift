//
//  Annotation.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import Accelerate
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

/// A single canvas annotation, unifying the concrete kinds so the editor can
/// store one ordered array. Array order is z-order: the first element draws
/// at the bottom, the last draws on top, and hit testing walks the array in
/// reverse so the topmost annotation wins regardless of kind.
enum Annotation: Identifiable, Equatable {
    case arrow(ArrowAnnotation)
    case text(TextAnnotation)
    case rectangle(RectangleAnnotation)

    var id: UUID {
        switch self {
        case .arrow(let arrow): arrow.id
        case .text(let text): text.id
        case .rectangle(let rectangle): rectangle.id
        }
    }

    var arrow: ArrowAnnotation? {
        if case .arrow(let arrow) = self { arrow } else { nil }
    }

    var text: TextAnnotation? {
        if case .text(let text) = self { text } else { nil }
    }

    var rectangle: RectangleAnnotation? {
        if case .rectangle(let rectangle) = self { rectangle } else { nil }
    }

    var color: Color {
        get {
            switch self {
            case .arrow(let arrow): arrow.color
            case .text(let text): text.color
            case .rectangle(let rectangle): rectangle.color
            }
        }
        set {
            switch self {
            case .arrow(var arrow):
                arrow.color = newValue
                self = .arrow(arrow)
            case .text(var text):
                text.color = newValue
                self = .text(text)
            case .rectangle(var rectangle):
                rectangle.color = newValue
                self = .rectangle(rectangle)
            }
        }
    }

    /// Returns a copy with a fresh id, shifted by `offset` so the duplicate
    /// is visually distinguishable from the original.
    func duplicated(offset: CGSize) -> Annotation {
        switch self {
        case .arrow(let arrow): .arrow(arrow.duplicated(offset: offset))
        case .text(let text): .text(text.duplicated(offset: offset))
        case .rectangle(let rectangle): .rectangle(rectangle.duplicated(offset: offset))
        }
    }

    /// Returns a copy (same id) translated by `offset`.
    func translated(by offset: CGSize) -> Annotation {
        switch self {
        case .arrow(var arrow):
            arrow.start.x += offset.width
            arrow.start.y += offset.height
            arrow.end.x += offset.width
            arrow.end.y += offset.height
            return .arrow(arrow)
        case .text(var text):
            text.position.x += offset.width
            text.position.y += offset.height
            return .text(text)
        case .rectangle(var rectangle):
            rectangle.rect = rectangle.rect.offsetBy(dx: offset.width, dy: offset.height)
            return .rectangle(rectangle)
        }
    }

    /// Returns a copy with all geometry scaled by (sx, sy) — used when the
    /// underlying image is resized. Stroke widths and font size scale by the
    /// smaller factor so annotations stay proportionate without distorting.
    func scaled(sx: CGFloat, sy: CGFloat) -> Annotation {
        let uniform = min(sx, sy)
        switch self {
        case .arrow(var arrow):
            arrow.start.x *= sx
            arrow.start.y *= sy
            arrow.end.x *= sx
            arrow.end.y *= sy
            arrow.lineWidth *= uniform
            return .arrow(arrow)
        case .text(var text):
            text.position.x *= sx
            text.position.y *= sy
            text.fontSize *= uniform
            return .text(text)
        case .rectangle(var rectangle):
            let r = rectangle.rect
            rectangle.rect = CGRect(
                x: r.origin.x * sx,
                y: r.origin.y * sy,
                width: r.width * sx,
                height: r.height * sy
            )
            rectangle.lineWidth *= uniform
            return .rectangle(rectangle)
        }
    }

    /// Returns a copy repositioned for a 90° rotation of an image that was
    /// `imageWidth` × `imageHeight` points before the rotation.
    func rotated90(clockwise: Bool, imageWidth w: CGFloat, imageHeight h: CGFloat) -> Annotation {
        func rotate(_ point: CGPoint) -> CGPoint {
            clockwise
                ? CGPoint(x: h - point.y, y: point.x)
                : CGPoint(x: point.y, y: w - point.x)
        }
        switch self {
        case .arrow(var arrow):
            arrow.start = rotate(arrow.start)
            arrow.end = rotate(arrow.end)
            return .arrow(arrow)
        case .text(var text):
            text.position = rotate(text.position)
            text.rotation += clockwise ? 90 : -90
            return .text(text)
        case .rectangle(var rectangle):
            let bounds = rectangle.rect.standardized
            let p1 = rotate(CGPoint(x: bounds.minX, y: bounds.minY))
            let p2 = rotate(CGPoint(x: bounds.maxX, y: bounds.maxY))
            rectangle.rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
            return .rectangle(rectangle)
        }
    }
}

extension Array where Element == Annotation {
    /// Locates the annotation with the given id and applies an in-place
    /// mutation. Does nothing if no matching annotation exists.
    mutating func update(id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = firstIndex(where: { $0.id == id }) else { return }
        body(&self[i])
    }

    /// Typed variant — a no-op when the id doesn't belong to an arrow.
    mutating func updateArrow(id: UUID, _ body: (inout ArrowAnnotation) -> Void) {
        update(id: id) {
            guard case .arrow(var arrow) = $0 else { return }
            body(&arrow)
            $0 = .arrow(arrow)
        }
    }

    /// Typed variant — a no-op when the id doesn't belong to a text annotation.
    mutating func updateText(id: UUID, _ body: (inout TextAnnotation) -> Void) {
        update(id: id) {
            guard case .text(var text) = $0 else { return }
            body(&text)
            $0 = .text(text)
        }
    }

    /// Typed variant — a no-op when the id doesn't belong to a rectangle.
    mutating func updateRectangle(id: UUID, _ body: (inout RectangleAnnotation) -> Void) {
        update(id: id) {
            guard case .rectangle(var rectangle) = $0 else { return }
            body(&rectangle)
            $0 = .rectangle(rectangle)
        }
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

    /// Returns a new image scaled to `newSize` (in points), preserving the
    /// source bitmap's pixel density so Retina images stay crisp.
    func resized(to newSize: NSSize) -> NSImage? {
        guard newSize.width >= 1, newSize.height >= 1 else { return nil }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0,
              let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let sx = CGFloat(cgImage.width) / pointSize.width
        let sy = CGFloat(cgImage.height) / pointSize.height
        let pixelWidth = max(1, Int((newSize.width * sx).rounded()))
        let pixelHeight = max(1, Int((newSize.height * sy).rounded()))

        guard let context = Self.bitmapContext(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: newSize)
    }

    /// Shared Core Image context for pixelation. CIContexts are expensive to
    /// set up and designed for reuse; sharing one avoids re-paying Metal
    /// pipeline warmup on every filter pass.
    private static let pixellateContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Runs `CIPixellate` over `source` with the block grid anchored at
    /// `gridAnchor`, expressed in the source's bottom-left-origin pixel space.
    private static func pixellated(
        _ source: CGImage, scalePixels: CGFloat, gridAnchor: CGPoint
    ) -> CGImage? {
        let filter = CIFilter.pixellate()
        let input = CIImage(cgImage: source)
        filter.inputImage = input
        filter.scale = Float(scalePixels)
        filter.center = gridAnchor
        guard let output = filter.outputImage else { return nil }
        return pixellateContext.createCGImage(output, from: input.extent)
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

        // CIPixellate's `scale` is in pixels — scale up to match Retina
        // assets. Anchor the grid at the image origin so blocks start
        // cleanly at the edge.
        let pixelsPerPoint = CGFloat(cgImage.width) / pointSize.width
        guard let rendered = Self.pixellated(
            cgImage, scalePixels: max(1, blockSize * pixelsPerPoint), gridAnchor: .zero
        ) else { return nil }
        return NSImage(cgImage: rendered, size: pointSize)
    }

    /// Returns a copy of this image with the given canvas-point rect replaced
    /// by a pixelated version of the underlying pixels. The rest of the
    /// bitmap is untouched. Used by the destructive pixelate tool — once
    /// applied, only an explicit Undo can recover the original pixels.
    ///
    /// Only the affected patch is filtered, not the whole bitmap — pixelating
    /// a small region of a large screenshot costs patch-sized CIPixellate
    /// work rather than two extra full-size renders.
    func pixelating(rect: CGRect, blockSize: CGFloat) -> NSImage? {
        guard let originalCG = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelW = CGFloat(originalCG.width)
        let pixelH = CGFloat(originalCG.height)
        let sx = pixelW / pointSize.width
        let fullPixelRect = CGRect(x: 0, y: 0, width: pixelW, height: pixelH)

        guard let pixelRect = pixelationBounds(for: rect) else { return self }

        // Crop the patch to filter, expanded outward to the pixellate block
        // grid so its blocks land exactly where a full-image pass would put
        // them — the live drag preview clips a full-image pixelated copy, and
        // the committed blocks must not shift relative to it.
        let scalePixels = max(1, blockSize * sx)
        let alignedMinX = floor(pixelRect.minX / scalePixels) * scalePixels
        let alignedMinY = floor(pixelRect.minY / scalePixels) * scalePixels
        let cropRect = CGRect(
            x: alignedMinX,
            y: alignedMinY,
            width: ceil(pixelRect.maxX / scalePixels) * scalePixels - alignedMinX,
            height: ceil(pixelRect.maxY / scalePixels) * scalePixels - alignedMinY
        ).intersection(fullPixelRect).integral

        // CGImage.cropping uses top-left-origin pixel coordinates.
        guard let patchCG = originalCG.cropping(to: CGRect(
            x: cropRect.minX,
            y: pixelH - cropRect.maxY,
            width: cropRect.width,
            height: cropRect.height
        )) else { return nil }

        // Re-anchor the block grid to compensate for the crop offset: in the
        // patch's coordinate space, the image origin sits at -cropRect.origin.
        // Zero whenever the crop landed exactly on the grid.
        let gridAnchor = CGPoint(
            x: -cropRect.minX.truncatingRemainder(dividingBy: scalePixels),
            y: -cropRect.minY.truncatingRemainder(dividingBy: scalePixels)
        )
        guard let pixelatedPatch = Self.pixellated(
            patchCG, scalePixels: scalePixels, gridAnchor: gridAnchor
        ) else { return nil }

        guard let context = Self.bitmapContext(pixelWidth: Int(pixelW), pixelHeight: Int(pixelH))
        else { return nil }
        context.draw(originalCG, in: fullPixelRect)

        // Stamp the pixelated patch at its aligned position, clipped to the
        // exact target rect so partial edge blocks don't spill outside it.
        context.saveGState()
        context.clip(to: pixelRect)
        context.draw(pixelatedPatch, in: cropRect)
        context.restoreGState()

        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: pointSize)
    }

    /// The region of the bitmap (bottom-left-origin pixel space) that
    /// `pixelating(rect:blockSize:)` modifies for a canvas-point `rect`, or
    /// nil when the rect misses the bitmap. Undo captures exactly this region.
    func pixelationBounds(for rect: CGRect) -> CGRect? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let sx = pixelW / pointSize.width
        let sy = pixelH / pointSize.height

        // Convert the canvas-point rect (top-left origin) into bottom-left-
        // origin pixel space.
        let pixelRect = CGRect(
            x: rect.minX * sx,
            y: pixelH - rect.maxY * sy,
            width: rect.width * sx,
            height: rect.height * sy
        ).integral.intersection(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))

        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return pixelRect
    }

    /// An independent copy of the pixels inside `pixelRect` (bottom-left-
    /// origin pixel space). Unlike `CGImage.cropping`, the result owns its
    /// backing store, so retaining it — e.g. in undo history — doesn't pin
    /// this image's full bitmap.
    func pixelPatch(in pixelRect: CGRect) -> NSImage? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = Self.bitmapContext(
                  pixelWidth: Int(pixelRect.width), pixelHeight: Int(pixelRect.height)
              )
        else { return nil }
        // Draw the full image offset so `pixelRect` lands on the context.
        context.draw(cgImage, in: CGRect(
            x: -pixelRect.minX,
            y: -pixelRect.minY,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: pixelRect.size)
    }

    /// Returns a copy of this image with `patch` replacing the pixels in
    /// `pixelRect` (bottom-left-origin pixel space). Inverse of the pixelate
    /// stamp: undo re-applies a region's saved original pixels, redo the
    /// pixelated ones.
    func stampingPatch(_ patch: NSImage, at pixelRect: CGRect) -> NSImage? {
        guard let baseCG = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let patchCG = patch.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = Self.bitmapContext(pixelWidth: baseCG.width, pixelHeight: baseCG.height)
        else { return nil }
        context.draw(baseCG, in: CGRect(x: 0, y: 0, width: baseCG.width, height: baseCG.height))
        // Replace outright rather than blend, so partially transparent
        // originals restore exactly.
        context.setBlendMode(.copy)
        context.draw(patchCG, in: pixelRect)
        guard let output = context.makeImage() else { return nil }
        return NSImage(cgImage: output, size: size)
    }

    /// Returns a new image rotated by 90° with swapped dimensions, preserving
    /// the source bitmap's pixel resolution. Uses Accelerate's SIMD rotate,
    /// which is an order of magnitude faster than drawing through a rotated
    /// `CGContext` for large screenshots.
    func rotated(clockwise: Bool) -> NSImage? {
        let pointSize = size
        guard pointSize.width > 0, pointSize.height > 0,
              let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil),
              var format = vImage_CGImageFormat(
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  colorSpace: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
              )
        else { return nil }

        // `InitWithCGImage` converts any source format (BGRA screenshots,
        // 16-bit, wide gamut) into the 8-bit RGBA layout above — the same
        // normalization every other edit operation applies via bitmapContext.
        var source = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(
            &source, &format, nil, cgImage, vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return nil }
        defer { free(source.data) }

        var rotated = vImage_Buffer()
        guard vImageBuffer_Init(
            &rotated,
            vImagePixelCount(cgImage.width),   // rotated height
            vImagePixelCount(cgImage.height),  // rotated width
            32,
            vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return nil }
        defer { free(rotated.data) }

        var background: [UInt8] = [0, 0, 0, 0]
        guard vImageRotate90_ARGB8888(
            &source,
            &rotated,
            UInt8(clockwise ? kRotate90DegreesClockwise : kRotate90DegreesCounterClockwise),
            &background,
            vImage_Flags(kvImageNoFlags)
        ) == kvImageNoError else { return nil }

        var error: vImage_Error = kvImageNoError
        let output = vImageCreateCGImageFromBuffer(
            &rotated, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error
        )
        guard error == kvImageNoError, let rotatedCG = output?.takeRetainedValue()
        else { return nil }
        return NSImage(
            cgImage: rotatedCG,
            size: NSSize(width: pointSize.height, height: pointSize.width)
        )
    }

    /// An RGBA bitmap context for rasterizing image edits offscreen. Editing
    /// operations draw into one of these and wrap the result in a fresh
    /// `NSImage` so edited images carry no reference to their predecessors —
    /// unlike `NSImage` drawing handlers, which retain their source image and
    /// re-rasterize it on every draw.
    private static func bitmapContext(pixelWidth: Int, pixelHeight: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
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
