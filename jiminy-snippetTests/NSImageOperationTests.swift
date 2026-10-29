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

    /// Visits every pixel of a `size`×`size` 1x image, passing its RGBA byte
    /// offset and whether its center lies inside `rect` (top-left point space).
    private func forEachPixel(
        size: Int, rect: CGRect, _ body: (_ offset: Int, _ inside: Bool) -> Void
    ) {
        for y in 0 ..< size {
            for x in 0 ..< size {
                // rgbaBytes rows are top-to-bottom and the image is 1x, so
                // buffer coordinates match the rect's top-left point space.
                let center = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                body((y * size + x) * 4, rect.contains(center))
            }
        }
    }

    /// Black image with a white square at `rect` (top-left point space).
    private func makeWhiteSquareOnBlack(size: Int, rect: CGRect) -> NSImage {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(
            x: rect.minX, y: CGFloat(size) - rect.maxY, width: rect.width, height: rect.height
        ))
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: size, height: size))
    }

    /// Blocks straddling the rect's edges must take their color from inside
    /// the rect. Regression: a block whose center fell outside the selection
    /// painted a strip of the surrounding image's color along the edge. The
    /// rect is chosen off the block grid so every edge cuts through blocks.
    @Test func pixelatingNeverSamplesColorsFromOutsideRect() throws {
        let size = 64
        let rect = CGRect(x: 13, y: 17, width: 25, height: 22)
        let original = makeWhiteSquareOnBlack(size: size, rect: rect)

        let committed = try #require(original.pixelating(rect: rect, blockSize: 10))
        let bytes = try #require(rgbaBytes(of: committed))

        var nonWhiteInside = 0
        forEachPixel(size: size, rect: rect) { i, inside in
            if inside, !isWhite(Array(bytes[i ..< i + 4])) {
                nonWhiteInside += 1
            }
        }
        #expect(nonWhiteInside == 0)
    }

    @Test func pixelatingLeavesPixelsOutsideRectUntouched() throws {
        let size = 64
        let original = makeGradientImage(size: size)
        let rect = CGRect(x: 13, y: 17, width: 25, height: 22)

        let committed = try #require(original.pixelating(rect: rect, blockSize: 10))
        let originalBytes = try #require(rgbaBytes(of: original))
        let committedBytes = try #require(rgbaBytes(of: committed))

        var outsideMismatches = 0
        forEachPixel(size: size, rect: rect) { i, inside in
            if !inside, committedBytes[i ..< i + 4] != originalBytes[i ..< i + 4] {
                outsideMismatches += 1
            }
        }
        #expect(outsideMismatches == 0)
    }

    /// The block grid is anchored at the image origin, not the selection, so
    /// separate redactions line up. Blocks lying wholly inside the rect must
    /// match a whole-image pass. Any pixel at least one block from every edge
    /// sits in such a block whatever the grid phase.
    @Test func pixelatingKeepsBlockGridAnchoredToImageOrigin() throws {
        let size = 64
        let blockSize: CGFloat = 10
        let original = makeGradientImage(size: size)
        let rect = CGRect(x: 13, y: 7, width: 41, height: 44)
        let wholeImage = CGRect(x: 0, y: 0, width: size, height: size)

        let committed = try #require(original.pixelating(rect: rect, blockSize: blockSize))
        let reference = try #require(original.pixelating(rect: wholeImage, blockSize: blockSize))
        let committedBytes = try #require(rgbaBytes(of: committed))
        let referenceBytes = try #require(rgbaBytes(of: reference))

        var mismatches = 0
        forEachPixel(size: size, rect: rect.insetBy(dx: blockSize, dy: blockSize)) { i, inside in
            guard inside else { return }
            for c in i ..< i + 4 {
                // Separate Core Image render passes; allow float rounding wiggle.
                if abs(Int(committedBytes[c]) - Int(referenceBytes[c])) > 2 {
                    mismatches += 1
                }
            }
        }
        #expect(mismatches == 0)
    }
}
