//
//  TestSupport.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import AppKit
import CoreGraphics
@testable import jiminy_snippet

/// A bitmap-backed image suitable for document operations (crop, pixelate,
/// export) that need a rasterizable representation.
func makeTestImage(width: CGFloat = 100, height: CGFloat = 100) -> NSImage {
    NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        NSColor.systemRed.setFill()
        rect.fill()
        return true
    }
}

/// A 1x image where every pixel has a distinct color, so any block-grid
/// phase error or unintended pixel change shows up as a byte difference.
func makeGradientImage(size: Int = 64) -> NSImage {
    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0 ..< size {
        for x in 0 ..< size {
            let i = (y * size + x) * 4
            bytes[i] = UInt8((x * 4) % 256)
            bytes[i + 1] = UInt8((y * 4) % 256)
            bytes[i + 2] = UInt8(((x + y) * 2) % 256)
            bytes[i + 3] = 255
        }
    }
    let cg = bytes.withUnsafeMutableBytes { ptr in
        CGContext(
            data: ptr.baseAddress, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
    }
    return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
}

/// Renders `image` into an RGBA8 bitmap and returns the raw bytes, rows
/// ordered top-to-bottom. Nil when the image can't be rasterized.
func rgbaBytes(of image: NSImage) -> [UInt8]? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var buffer = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
    let rendered = buffer.withUnsafeMutableBytes { ptr -> Bool in
        guard let ctx = CGContext(
            data: ptr.baseAddress, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return true
    }
    return rendered ? buffer : nil
}

/// The RGBA components of the pixel at (`x`, `y`) measured from the image's
/// visual top-left corner.
func pixelRGBA(in image: NSImage, x: Int, y: Int) -> [UInt8]? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          x >= 0, y >= 0, x < cg.width, y < cg.height,
          let bytes = rgbaBytes(of: image)
    else { return nil }
    let start = (y * cg.width + x) * 4
    return Array(bytes[start ..< start + 4])
}

func approxEqual(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
    abs(a - b) <= tolerance
}

func approxEqual(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 0.001) -> Bool {
    approxEqual(a.x, b.x, tolerance: tolerance) && approxEqual(a.y, b.y, tolerance: tolerance)
}

func approxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.001) -> Bool {
    approxEqual(a.origin.x, b.origin.x, tolerance: tolerance)
        && approxEqual(a.origin.y, b.origin.y, tolerance: tolerance)
        && approxEqual(a.width, b.width, tolerance: tolerance)
        && approxEqual(a.height, b.height, tolerance: tolerance)
}
