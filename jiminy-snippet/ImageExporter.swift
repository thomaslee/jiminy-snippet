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

    /// Burns the annotations into the image, preserving the source bitmap's
    /// full pixel resolution. Renders through the same SwiftUI `Canvas` code
    /// the editor uses on screen (`AnnotationRenderer.drawAnnotations`), so
    /// exports are WYSIWYG by construction — minus selection chrome.
    @MainActor
    static func render(image: NSImage, annotations: [Annotation]) -> NSImage {
        let pointSize = image.size
        guard pointSize.width > 0, pointSize.height > 0 else { return image }
        let pixelSize = pixelSize(of: image) ?? pointSize

        // Rasterize at the bitmap's native scale so a Retina capture exports
        // at its full pixel dimensions and a 1x image stays 1x.
        let scale = pixelSize.width / pointSize.width

        let content = Canvas { context, _ in
            context.draw(
                Image(nsImage: image),
                in: CGRect(origin: .zero, size: pointSize)
            )
            AnnotationRenderer.drawAnnotations(annotations, in: &context)
        }
        .frame(width: pointSize.width, height: pointSize.height)

        let renderer = ImageRenderer(content: content)

        // Draw into our own CGContext rather than reading `renderer.cgImage`,
        // so the output bitmap has exactly the requested pixel dimensions
        // regardless of the ambient display scale.
        var rendered: CGImage?
        renderer.render(rasterizationScale: scale) { size, renderFn in
            guard let context = CGContext(
                data: nil,
                width: Int((size.width * scale).rounded()),
                height: Int((size.height * scale).rounded()),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            // The render function draws in points; map them onto pixels.
            context.scaleBy(x: scale, y: scale)
            renderFn(context)
            rendered = context.makeImage()
        }

        guard let rendered else { return image }
        return NSImage(cgImage: rendered, size: pointSize)
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
}
