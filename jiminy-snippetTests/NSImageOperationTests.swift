//
//  NSImageOperationTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import AppKit
import Testing
@testable import jiminy_snippet

/// Pixel-level tests for the destructive NSImage edit operations. These pin
/// down the visual rotation direction so the implementation can be swapped
/// (CoreGraphics ↔ vImage) without silently flipping orientation.
struct NSImageOperationTests {
    private let width = 40
    private let height = 20

    /// White image with a red marker square in the visual top-left corner.
    private func makeMarkedImage() -> NSImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext origin is bottom-left, so the visual top-left corner is
        // at the context's maximum y.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: CGFloat(height) - 10, width: 10, height: 10))
        return NSImage(
            cgImage: ctx.makeImage()!,
            size: NSSize(width: width, height: height)
        )
    }

    private func isRed(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] < 50 && p[2] < 50 }
    private func isWhite(_ p: [UInt8]) -> Bool { p[0] > 200 && p[1] > 200 && p[2] > 200 }

    @Test func rotatedClockwiseMovesTopLeftMarkerToTopRight() throws {
        let rotated = try #require(makeMarkedImage().rotated(clockwise: true))
        #expect(rotated.size == NSSize(width: height, height: width))
        #expect(isRed(try #require(pixelRGBA(in: rotated, x: height - 5, y: 5))))
        #expect(isWhite(try #require(pixelRGBA(in: rotated, x: 5, y: 5))))
    }

    @Test func rotatedCounterClockwiseMovesTopLeftMarkerToBottomLeft() throws {
        let rotated = try #require(makeMarkedImage().rotated(clockwise: false))
        #expect(rotated.size == NSSize(width: height, height: width))
        #expect(isRed(try #require(pixelRGBA(in: rotated, x: 5, y: width - 5))))
        #expect(isWhite(try #require(pixelRGBA(in: rotated, x: 5, y: 5))))
    }

    @Test func rotationRoundTripRestoresPixels() throws {
        let original = makeMarkedImage()
        let roundTripped = try #require(
            original.rotated(clockwise: true)?.rotated(clockwise: false)
        )
        #expect(rgbaBytes(of: roundTripped) == rgbaBytes(of: original))
    }

    // MARK: - Pixelation

    /// 1x image where every pixel has a distinct color, so any block-grid
    /// phase error in pixelation shows up as a byte difference.
    private func makeGradientImage(size: Int = 64) -> NSImage {
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

    /// The commit (`pixelating(rect:)`) must produce the same blocks the live
    /// drag preview shows — which clips a full-image `pixelated()` copy — and
    /// must leave every pixel outside the rect untouched. The rect is chosen
    /// off the block grid so grid-anchoring mistakes can't hide.
    @Test func pixelatingMatchesPreviewInsideRectAndOriginalOutside() throws {
        let size = 64
        let original = makeGradientImage(size: size)
        let rect = CGRect(x: 13, y: 17, width: 25, height: 22)

        let committed = try #require(original.pixelating(rect: rect, blockSize: 10))
        let preview = try #require(original.pixelated(blockSize: 10))

        let originalBytes = try #require(rgbaBytes(of: original))
        let committedBytes = try #require(rgbaBytes(of: committed))
        let previewBytes = try #require(rgbaBytes(of: preview))

        var insideMismatches = 0
        var outsideMismatches = 0
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                // rgbaBytes rows are top-to-bottom and the image is 1x, so
                // buffer coordinates match the rect's top-left point space.
                let inside = rect.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                for c in 0 ..< 4 {
                    if inside {
                        // Preview and commit may take separate Core Image
                        // render passes; allow float rounding wiggle.
                        if abs(Int(committedBytes[i + c]) - Int(previewBytes[i + c])) > 2 {
                            insideMismatches += 1
                        }
                    } else if committedBytes[i + c] != originalBytes[i + c] {
                        outsideMismatches += 1
                    }
                }
            }
        }
        #expect(insideMismatches == 0)
        #expect(outsideMismatches == 0)
    }
}
