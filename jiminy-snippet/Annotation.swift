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

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }
}

struct ArrowAnnotation: Identifiable, Equatable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var lineWidth: CGFloat = 4
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
