//
//  CanvasDragControllerTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

@MainActor
struct CanvasDragControllerTests {

    private func makeDocument(annotations: [Annotation] = []) -> AnnotationDocument {
        let document = AnnotationDocument()
        document.image = makeTestImage(width: 200, height: 200)
        document.annotations = annotations
        return document
    }

    private func makeContext(
        document: AnnotationDocument,
        tool: AnnotationTool? = nil,
        cropMode: Bool = false,
        shiftPressed: Bool = false
    ) -> CanvasDragController.Context {
        CanvasDragController.Context(
            document: document,
            imageSize: CGSize(width: 200, height: 200),
            selectedTool: tool,
            selectedColor: .red,
            rectangleFillStyle: .outlined,
            cropMode: cropMode,
            shiftPressed: shiftPressed,
            textSizes: [:]
        )
    }

    /// Drives a full drag from `start` to `end` through the controller.
    private func drag(
        _ controller: inout CanvasDragController,
        from start: CGPoint,
        to end: CGPoint,
        context: CanvasDragController.Context
    ) -> CanvasDragController.EndEffect {
        let translation = CGSize(width: end.x - start.x, height: end.y - start.y)
        controller.dragChanged(
            location: end, translation: translation, startLocation: start, context: context
        )
        return controller.dragEnded(location: end, context: context)
    }

    // MARK: - Creation

    @Test func arrowToolDragCreatesSelectedArrowAndRecordsUndo() {
        let document = makeDocument()
        var controller = CanvasDragController()
        let context = makeContext(document: document, tool: .arrow)

        let effect = drag(
            &controller, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 40),
            context: context
        )

        #expect(effect == .toolFinished)
        #expect(document.annotations.count == 1)
        #expect(document.annotations[0].arrow?.start == CGPoint(x: 10, y: 10))
        #expect(document.annotations[0].arrow?.end == CGPoint(x: 60, y: 40))
        #expect(document.selectedAnnotationIds == [document.annotations[0].id])
        #expect(document.canUndo)
    }

    @Test func tinyRectangleDragCreatesNothing() {
        let document = makeDocument()
        var controller = CanvasDragController()
        let context = makeContext(document: document, tool: .rectangle)

        let effect = drag(
            &controller, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10.5, y: 10.5),
            context: context
        )

        #expect(effect == .toolFinished)
        #expect(document.annotations.isEmpty)
    }

    // MARK: - Moving

    @Test func bodyDragMovesRectangleFromStableBase() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 10, y: 10, width: 50, height: 50), color: .red, style: .filled
        )
        let document = makeDocument(annotations: [.rectangle(rectangle)])
        var controller = CanvasDragController()
        let context = makeContext(document: document)

        // Two updates from the same drag: position derives from the initial
        // rect + total translation, not compounding per-event deltas.
        controller.dragChanged(
            location: CGPoint(x: 45, y: 40), translation: CGSize(width: 10, height: 5),
            startLocation: CGPoint(x: 35, y: 35), context: context
        )
        controller.dragChanged(
            location: CGPoint(x: 55, y: 45), translation: CGSize(width: 20, height: 10),
            startLocation: CGPoint(x: 35, y: 35), context: context
        )
        _ = controller.dragEnded(location: CGPoint(x: 55, y: 45), context: context)

        #expect(document.annotations[0].rectangle?.rect
            == CGRect(x: 30, y: 20, width: 50, height: 50))
        #expect(document.selectedAnnotationIds == [rectangle.id])
        #expect(document.canUndo)
    }

    @Test func shiftDragOnAnnotationBodyDoesNothing() {
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 10, y: 10, width: 50, height: 50), color: .red, style: .filled
        )
        let document = makeDocument(annotations: [.rectangle(rectangle)])
        var controller = CanvasDragController()
        let context = makeContext(document: document, shiftPressed: true)

        let effect = drag(
            &controller, from: CGPoint(x: 35, y: 35), to: CGPoint(x: 80, y: 80),
            context: context
        )

        #expect(effect == .none)
        #expect(document.annotations[0].rectangle?.rect == rectangle.rect)
        #expect(!document.canUndo)
    }

    @Test func bodyDragOnMultiSelectionMovesWholeGroup() {
        let first = RectangleAnnotation(
            rect: CGRect(x: 10, y: 10, width: 40, height: 40), color: .red, style: .filled
        )
        let second = ArrowAnnotation(
            start: CGPoint(x: 100, y: 100), end: CGPoint(x: 140, y: 140), color: .red
        )
        let document = makeDocument(annotations: [.rectangle(first), .arrow(second)])
        document.selectedAnnotationIds = [first.id, second.id]
        var controller = CanvasDragController()
        let context = makeContext(document: document)

        _ = drag(
            &controller, from: CGPoint(x: 30, y: 30), to: CGPoint(x: 40, y: 50),
            context: context
        )

        #expect(document.annotations[0].rectangle?.rect
            == CGRect(x: 20, y: 30, width: 40, height: 40))
        #expect(document.annotations[1].arrow?.start == CGPoint(x: 110, y: 120))
        #expect(document.selectedAnnotationIds == [first.id, second.id])
    }

    // MARK: - Marquee selection

    @Test func marqueeReplacesSelectionWithIntersectingAnnotations() {
        let near = RectangleAnnotation(
            rect: CGRect(x: 20, y: 20, width: 20, height: 20), color: .red, style: .filled
        )
        let far = ArrowAnnotation(
            start: CGPoint(x: 150, y: 150), end: CGPoint(x: 180, y: 180), color: .red
        )
        let document = makeDocument(annotations: [.rectangle(near), .arrow(far)])
        document.selectedAnnotationIds = [far.id]
        var controller = CanvasDragController()
        let context = makeContext(document: document)

        _ = drag(
            &controller, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 60),
            context: context
        )

        #expect(document.selectedAnnotationIds == [near.id])
        // Selection changes alone must not burn an undo slot.
        #expect(!document.canUndo)
    }

    @Test func shiftMarqueeExtendsExistingSelection() {
        let near = RectangleAnnotation(
            rect: CGRect(x: 20, y: 20, width: 20, height: 20), color: .red, style: .filled
        )
        let far = ArrowAnnotation(
            start: CGPoint(x: 150, y: 150), end: CGPoint(x: 180, y: 180), color: .red
        )
        let document = makeDocument(annotations: [.rectangle(near), .arrow(far)])
        document.selectedAnnotationIds = [far.id]
        var controller = CanvasDragController()
        let context = makeContext(document: document, shiftPressed: true)

        _ = drag(
            &controller, from: CGPoint(x: 5, y: 5), to: CGPoint(x: 60, y: 60),
            context: context
        )

        #expect(document.selectedAnnotationIds == [near.id, far.id])
    }

    // MARK: - Crop

    @Test func cropDragReportsRegionClampedToImage() {
        let document = makeDocument()
        var controller = CanvasDragController()
        let context = makeContext(document: document, cropMode: true)

        let effect = drag(
            &controller, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 300, y: 300),
            context: context
        )

        #expect(effect == .cropSelected(CGRect(x: 20, y: 20, width: 180, height: 180)))
        // Crop selection is not undoable canvas state — no snapshot yet.
        #expect(!document.canUndo)
    }

    @Test func tinyCropDragReportsNilRegion() {
        let document = makeDocument()
        var controller = CanvasDragController()
        let context = makeContext(document: document, cropMode: true)

        let effect = drag(
            &controller, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20.5, y: 20.5),
            context: context
        )

        #expect(effect == .cropSelected(nil))
    }
}
