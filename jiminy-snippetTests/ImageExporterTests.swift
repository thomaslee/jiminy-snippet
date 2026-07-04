//
//  ImageExporterTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

@MainActor
struct ImageExporterTests {

    /// A `pointSize`-point image backed by a bitmap of `pixelsWide` pixels,
    /// mimicking a Retina screenshot when the two differ.
    private func makeImage(pointSize: CGFloat, pixelsWide: Int) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide, pixelsHigh: pixelsWide,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        return image
    }

    /// Pixel width of the image as it would land on disk. Measured through
    /// the real save path because `representations` on a cgImage-backed
    /// NSImage reports pointSize × screen scale, not the bitmap's true size.
    private func savedPixelWidth(of image: NSImage) throws -> Int? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jiminy-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ImageExporter.save(image: image, to: url)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)?.pixelsWide
    }

    @Test func renderPreservesRetinaPixelResolution() throws {
        // 50-point image backed by a 100-pixel bitmap (2x).
        let image = makeImage(pointSize: 50, pixelsWide: 100)
        let arrow = ArrowAnnotation(
            start: CGPoint(x: 5, y: 5), end: CGPoint(x: 40, y: 40), color: .red
        )

        let rendered = ImageExporter.render(image: image, annotations: [.arrow(arrow)])

        #expect(rendered.size == NSSize(width: 50, height: 50))
        #expect(try savedPixelWidth(of: rendered) == 100)
    }

    @Test func renderAt1xKeepsPixelDimensions() throws {
        let image = makeImage(pointSize: 64, pixelsWide: 64)
        let rendered = ImageExporter.render(image: image, annotations: [])
        #expect(try savedPixelWidth(of: rendered) == 64)
    }

    @Test func renderPreservesImageOrientation() {
        // Source: top half blue, bottom half white. (The drawing handler uses
        // a bottom-left origin, so the top half is the upper y range.)
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 4).fill()
            NSColor.blue.setFill()
            NSRect(x: 0, y: 4, width: 8, height: 4).fill()
            return true
        }

        let rendered = ImageExporter.render(image: image, annotations: [])

        guard let cgImage = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("render produced no rasterizable image")
            return
        }
        // NSBitmapImageRep's colorAt is top-left origin: row 0 must be blue.
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let top = bitmap.colorAt(x: 4, y: 1)?.usingColorSpace(.sRGB)
        let bottom = bitmap.colorAt(x: 4, y: 6)?.usingColorSpace(.sRGB)
        #expect((top?.blueComponent ?? 0) > 0.8)
        #expect((top?.redComponent ?? 1) < 0.5)
        #expect((bottom?.redComponent ?? 0) > 0.8)
    }
}
