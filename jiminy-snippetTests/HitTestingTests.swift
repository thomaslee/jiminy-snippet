//
//  HitTestingTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

struct HitTestingTests {

    // MARK: - Arrows

    @Test func arrowBodyHitWithinHitWidth() {
        let arrow = ArrowAnnotation(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .red
        )
        let hit = hitTestAnnotations(
            at: CGPoint(x: 50, y: 5),
            annotations: [.arrow(arrow)], selectedId: nil, textSizes: [:]
        )
        #expect(hit?.id == arrow.id)
        #expect(hit?.isBody == true)

        let miss = hitTestAnnotations(
            at: CGPoint(x: 50, y: 30),
            annotations: [.arrow(arrow)], selectedId: nil, textSizes: [:]
        )
        #expect(miss == nil)
    }

    @Test func arrowEndpointsOnlyHitWhenSelected() {
        let arrow = ArrowAnnotation(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .red
        )
        let annotations: [Annotation] = [.arrow(arrow)]

        let unselected = hitTestAnnotations(
            at: CGPoint(x: 0, y: 0), annotations: annotations, selectedId: nil, textSizes: [:]
        )
        #expect(unselected?.isBody == true)

        let selected = hitTestAnnotations(
            at: CGPoint(x: 0, y: 0), annotations: annotations,
            selectedId: arrow.id, textSizes: [:]
        )
        if case .arrow(_, .startEndpoint) = selected {} else {
            Issue.record("expected startEndpoint, got \(String(describing: selected))")
        }
    }

    // MARK: - Rectangles

    @Test func filledRectangleIsHitAnywhereInside() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: .red, style: .filled
        )
        let hit = hitTestAnnotations(
            at: CGPoint(x: 50, y: 50),
            annotations: [.rectangle(rectangle)], selectedId: nil, textSizes: [:]
        )
        #expect(hit?.id == rectangle.id)
    }

    @Test func outlinedRectangleIsOnlyHitNearItsStroke() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: .red, style: .outlined
        )
        let annotations: [Annotation] = [.rectangle(rectangle)]

        // Center misses so clicks pass through to whatever is behind.
        let center = hitTestAnnotations(
            at: CGPoint(x: 50, y: 50), annotations: annotations, selectedId: nil, textSizes: [:]
        )
        #expect(center == nil)

        // Near the stroke hits.
        let edge = hitTestAnnotations(
            at: CGPoint(x: 2, y: 50), annotations: annotations, selectedId: nil, textSizes: [:]
        )
        #expect(edge?.id == rectangle.id)
    }

    @Test func rectangleHandlesOnlyHitWhenSelected() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: .red, style: .filled
        )
        let annotations: [Annotation] = [.rectangle(rectangle)]
        let corner = CGPoint(x: 0, y: 0)

        let unselected = hitTestAnnotations(
            at: corner, annotations: annotations, selectedId: nil, textSizes: [:]
        )
        #expect(unselected?.isBody == true)

        let selected = hitTestAnnotations(
            at: corner, annotations: annotations, selectedId: rectangle.id, textSizes: [:]
        )
        if case .rectangle(_, .handle(.topLeft)) = selected {} else {
            Issue.record("expected topLeft handle, got \(String(describing: selected))")
        }
    }

    // MARK: - Text

    @Test func textBodyAndRotateHandleZones() {
        let text = TextAnnotation(position: CGPoint(x: 10, y: 10), text: "Hi", color: .red)
        let measured = CGSize(width: 50, height: 20)
        let annotations: [Annotation] = [.text(text)]
        let sizes = [text.id: measured]

        let body = hitTestAnnotations(
            at: CGPoint(x: 30, y: 20), annotations: annotations, selectedId: nil, textSizes: sizes
        )
        #expect(body?.id == text.id)
        #expect(body?.isBody == true)

        // Rotate handle floats rotateHandleOffset above the top-center of the
        // padded box (58×24 at position (10,10)) — only reachable when selected.
        let rotatePoint = CGPoint(x: 10 + 29, y: 10 - RenderConstants.rotateHandleOffset)
        let unselected = hitTestAnnotations(
            at: rotatePoint, annotations: annotations, selectedId: nil, textSizes: sizes
        )
        #expect(unselected == nil)

        let selected = hitTestAnnotations(
            at: rotatePoint, annotations: annotations, selectedId: text.id, textSizes: sizes
        )
        #expect(selected?.isRotateHandle == true)
    }

    // MARK: - Z-order

    @Test func topmostAnnotationWinsRegardlessOfKind() {
        let below = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 100, height: 100), color: .red, style: .filled
        )
        let above = ArrowAnnotation(
            start: CGPoint(x: 0, y: 50), end: CGPoint(x: 100, y: 50), color: .blue
        )
        // The arrow was added later, so it sits on top and wins the hit.
        let hit = hitTestAnnotations(
            at: CGPoint(x: 50, y: 50),
            annotations: [.rectangle(below), .arrow(above)],
            selectedId: nil, textSizes: [:]
        )
        #expect(hit?.id == above.id)

        // Away from the arrow, the rectangle underneath is hit.
        let hitBelow = hitTestAnnotations(
            at: CGPoint(x: 50, y: 80),
            annotations: [.rectangle(below), .arrow(above)],
            selectedId: nil, textSizes: [:]
        )
        #expect(hitBelow?.id == below.id)
    }
}
