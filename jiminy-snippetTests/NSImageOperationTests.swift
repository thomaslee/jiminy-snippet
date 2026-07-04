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
}
