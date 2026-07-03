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
