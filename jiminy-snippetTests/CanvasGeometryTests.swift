//
//  CanvasGeometryTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

struct CanvasGeometryTests {

    // MARK: - CGRect(from:to:)

    @Test func rectFromPointsNormalizesAnyCornerOrder() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(CGRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)) == expected)
        #expect(CGRect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)) == expected)
        #expect(CGRect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)) == expected)
    }

    // MARK: - Bounding boxes

    @Test func arrowBoundingBoxPadsForHeadWidth() {
        let arrow = ArrowAnnotation(
            start: CGPoint(x: 10, y: 10), end: CGPoint(x: 50, y: 30), color: .red
        )
        let pad = arrow.lineWidth * 3.2
        let expected = CGRect(x: 10, y: 10, width: 40, height: 20)
            .insetBy(dx: -pad, dy: -pad)
        #expect(arrow.boundingBox == expected)
    }

    @Test func unrotatedRectangleBoundingBoxIsItsRect() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 10, y: 20, width: 30, height: 40), color: .red, style: .filled
        )
        #expect(rectangle.boundingBox == rectangle.rect)
    }

    @Test func rotatedRectangleBoundingBoxSwapsDimensionsAt90Degrees() {
        var rectangle = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 100, height: 50), color: .red, style: .filled
        )
        rectangle.rotation = 90
        // Rotated around center (50, 25): the box becomes 50×100 centred there.
        #expect(approxEqual(rectangle.boundingBox, CGRect(x: 25, y: -25, width: 50, height: 100)))
    }

    @Test func textBoundingBoxAppliesPaddingAndScale() {
        var text = TextAnnotation(position: CGPoint(x: 10, y: 10), text: "Hi", color: .red)
        text.scaleX = 2
        let measured = CGSize(width: 50, height: 20)
        // Padded to 58×24, then scaled 2× horizontally.
        #expect(text.boundingBox(measuredSize: measured)
            == CGRect(x: 10, y: 10, width: 116, height: 24))
    }

    @Test func annotationsIntersectingSelectsOnlyOverlappingBoxes() {
        let near = RectangleAnnotation(
            rect: CGRect(x: 10, y: 10, width: 20, height: 20), color: .red, style: .filled
        )
        let far = ArrowAnnotation(
            start: CGPoint(x: 150, y: 150), end: CGPoint(x: 180, y: 180), color: .red
        )
        let ids = annotationsIntersecting(
            CGRect(x: 0, y: 0, width: 50, height: 50),
            annotations: [.rectangle(near), .arrow(far)],
            textSizes: [:]
        )
        #expect(ids == [near.id])
    }

    // MARK: - Rotated rectangle resize

    @Test func resizeRightHandleOfUnrotatedRectExtendsWidth() {
        let result = resizedRotatedRect(
            initial: CGRect(x: 0, y: 0, width: 100, height: 50),
            rotation: 0,
            handle: .right,
            localTranslation: CGSize(width: 20, height: 0)
        )
        #expect(approxEqual(result, CGRect(x: 0, y: 0, width: 120, height: 50)))
    }

    @Test func resizeTopLeftHandleKeepsOppositeCornerAnchored() {
        let result = resizedRotatedRect(
            initial: CGRect(x: 0, y: 0, width: 100, height: 50),
            rotation: 0,
            handle: .topLeft,
            localTranslation: CGSize(width: 10, height: 10)
        )
        // Bottom-right corner (100, 50) must not move.
        #expect(approxEqual(result, CGRect(x: 10, y: 10, width: 90, height: 40)))
    }

    @Test func resizeOfRotatedRectAppliesTranslationInLocalFrame() {
        // At 90° rotation, extending the local "right" edge by 20 grows the
        // width but shifts the center along the canvas *y* axis.
        let result = resizedRotatedRect(
            initial: CGRect(x: 0, y: 0, width: 100, height: 50),
            rotation: 90,
            handle: .right,
            localTranslation: CGSize(width: 20, height: 0)
        )
        #expect(approxEqual(result, CGRect(x: -10, y: 10, width: 120, height: 50)))
    }

    @Test func resizePastOppositeEdgeYieldsNonStandardizedRect() {
        let result = resizedRotatedRect(
            initial: CGRect(x: 0, y: 0, width: 100, height: 50),
            rotation: 0,
            handle: .right,
            localTranslation: CGSize(width: -150, height: 0)
        )
        // Width goes negative while dragging; callers standardize on drag end.
        // (`size.width` preserves the sign — `CGRect.width` would not.)
        #expect(result.size.width == -50)
        #expect(approxEqual(result.standardized.width, 50))
    }
}
