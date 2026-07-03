//
//  AnnotationTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

struct AnnotationTests {
    private let arrow = ArrowAnnotation(
        start: CGPoint(x: 10, y: 20), end: CGPoint(x: 30, y: 40), color: .red
    )
    private let text = TextAnnotation(
        position: CGPoint(x: 10, y: 20), text: "Hi", color: .blue
    )
    private let rectangle = RectangleAnnotation(
        rect: CGRect(x: 10, y: 20, width: 30, height: 40), color: .green, style: .outlined
    )

    // MARK: - Translation

    @Test func translatedShiftsGeometryAndPreservesId() {
        let offset = CGSize(width: 5, height: -5)

        let movedArrow = Annotation.arrow(arrow).translated(by: offset)
        #expect(movedArrow.id == arrow.id)
        #expect(movedArrow.arrow?.start == CGPoint(x: 15, y: 15))
        #expect(movedArrow.arrow?.end == CGPoint(x: 35, y: 35))

        let movedText = Annotation.text(text).translated(by: offset)
        #expect(movedText.id == text.id)
        #expect(movedText.text?.position == CGPoint(x: 15, y: 15))

        let movedRect = Annotation.rectangle(rectangle).translated(by: offset)
        #expect(movedRect.id == rectangle.id)
        #expect(movedRect.rectangle?.rect == CGRect(x: 15, y: 15, width: 30, height: 40))
    }

    // MARK: - Duplication

    @Test func duplicatedProducesFreshIdAtOffsetPosition() {
        let copy = Annotation.arrow(arrow).duplicated(offset: CGSize(width: 20, height: 20))
        #expect(copy.id != arrow.id)
        #expect(copy.arrow?.start == CGPoint(x: 30, y: 40))
        #expect(copy.arrow?.color == arrow.color)
    }

    // MARK: - Scaling (image resize)

    @Test func scaledScalesPositionsPerAxisAndWidthsUniformly() {
        let scaled = Annotation.arrow(arrow).scaled(sx: 2, sy: 3)
        #expect(scaled.arrow?.start == CGPoint(x: 20, y: 60))
        #expect(scaled.arrow?.end == CGPoint(x: 60, y: 120))
        // Stroke width scales by the smaller factor to avoid distortion.
        #expect(scaled.arrow?.lineWidth == arrow.lineWidth * 2)

        let scaledText = Annotation.text(text).scaled(sx: 2, sy: 3)
        #expect(scaledText.text?.position == CGPoint(x: 20, y: 60))
        #expect(scaledText.text?.fontSize == text.fontSize * 2)

        let scaledRect = Annotation.rectangle(rectangle).scaled(sx: 2, sy: 3)
        #expect(scaledRect.rectangle?.rect == CGRect(x: 20, y: 60, width: 60, height: 120))
    }

    // MARK: - 90° rotation (image rotate)

    @Test func rotated90MapsPointsClockwise() {
        // Clockwise on a 100×50 image: (x, y) → (h - y, x).
        let rotated = Annotation.arrow(arrow).rotated90(
            clockwise: true, imageWidth: 100, imageHeight: 50
        )
        #expect(rotated.arrow?.start == CGPoint(x: 30, y: 10))
        #expect(rotated.arrow?.end == CGPoint(x: 10, y: 30))
    }

    @Test func rotated90RoundTripsBackToOriginal() {
        let once = Annotation.rectangle(rectangle).rotated90(
            clockwise: true, imageWidth: 100, imageHeight: 50
        )
        // The image is now 50×100, so the inverse rotation swaps dimensions.
        let back = once.rotated90(clockwise: false, imageWidth: 50, imageHeight: 100)
        #expect(back.rectangle?.rect == rectangle.rect)
    }

    @Test func rotated90AdjustsTextRotation() {
        let rotated = Annotation.text(text).rotated90(
            clockwise: true, imageWidth: 100, imageHeight: 50
        )
        #expect(rotated.text?.rotation == text.rotation + 90)
    }

    // MARK: - Color

    @Test func colorSetterAppliesToAllKinds() {
        var annotation = Annotation.rectangle(rectangle)
        annotation.color = .orange
        #expect(annotation.color == .orange)
        #expect(annotation.rectangle?.style == rectangle.style)
    }

    // MARK: - Array update helpers

    @Test func typedUpdateMutatesOnlyMatchingKind() {
        var annotations: [Annotation] = [.arrow(arrow), .text(text)]

        annotations.updateArrow(id: arrow.id) { $0.lineWidth = 9 }
        #expect(annotations[0].arrow?.lineWidth == 9)

        // A typed update aimed at the wrong kind is a no-op.
        annotations.updateArrow(id: text.id) { $0.lineWidth = 99 }
        #expect(annotations[1].text == text)

        annotations.updateText(id: text.id) { $0.text = "Changed" }
        #expect(annotations[1].text?.text == "Changed")
    }
}
