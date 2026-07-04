//
//  AnnotationDocumentTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

@MainActor
struct AnnotationDocumentTests {

    private func makeDocument() -> AnnotationDocument {
        let document = AnnotationDocument()
        document.image = makeTestImage()
        return document
    }

    private func makeArrow() -> ArrowAnnotation {
        ArrowAnnotation(start: CGPoint(x: 30, y: 30), end: CGPoint(x: 60, y: 60), color: .red)
    }

    // MARK: - Loading

    @Test func loadImageResetsEditingState() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]
        document.selectedAnnotationIds = [arrow.id]
        document.recordSnapshot()

        let newImage = makeTestImage(width: 50, height: 50)
        document.loadImage(newImage)

        #expect(document.image === newImage)
        #expect(document.annotations.isEmpty)
        #expect(document.selectedAnnotationIds.isEmpty)
        #expect(!document.canUndo)
        #expect(document.hasUnsavedChanges)
    }

    // MARK: - Pixelation Undo

    private func imageBytes(of document: AnnotationDocument) throws -> [UInt8] {
        let image = try #require(document.image)
        return try #require(rgbaBytes(of: image))
    }

    @Test func pixelationUndoRestoresExactPixelsAndRedoReapplies() throws {
        let document = AnnotationDocument()
        document.image = makeGradientImage()
        // Deliberately off the pixelate block grid.
        let rect = CGRect(x: 13, y: 17, width: 25, height: 22)

        let originalBytes = try imageBytes(of: document)
        document.applyPixelation(rect: rect)
        let pixelatedBytes = try imageBytes(of: document)
        #expect(document.canUndo)
        #expect(pixelatedBytes != originalBytes)

        #expect(document.undo())
        #expect(try imageBytes(of: document) == originalBytes)
        #expect(document.canRedo)

        #expect(document.redo())
        #expect(try imageBytes(of: document) == pixelatedBytes)

        // Patches must survive repeated round trips.
        #expect(document.undo())
        #expect(try imageBytes(of: document) == originalBytes)
    }

    @Test func pixelationMissingTheImageRecordsNoUndo() {
        let document = makeDocument()
        let imageBefore = document.image
        document.applyPixelation(rect: CGRect(x: -50, y: -50, width: 10, height: 10))
        #expect(!document.canUndo)
        #expect(document.image === imageBefore)
    }

    // MARK: - Undo / Redo

    @Test func undoRestoresSnapshotAndRedoReappliesEdit() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]

        document.recordSnapshot()
        document.annotations.updateArrow(id: arrow.id) { $0.lineWidth = 20 }

        #expect(document.undo())
        #expect(document.annotations[0].arrow?.lineWidth == arrow.lineWidth)
        #expect(document.canRedo)

        #expect(document.redo())
        #expect(document.annotations[0].arrow?.lineWidth == 20)
    }

    @Test func undoWithEmptyHistoryReturnsFalse() {
        let document = makeDocument()
        #expect(!document.undo())
        #expect(!document.redo())
    }

    @Test func undoClearsSelection() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]
        document.recordSnapshot()
        document.selectedAnnotationIds = [arrow.id]

        document.undo()
        #expect(document.selectedAnnotationIds.isEmpty)
    }

    @Test func discardedSnapshotDoesNotBurnAnUndoSlot() {
        let document = makeDocument()
        document.recordSnapshot()
        document.discardLastSnapshot()
        #expect(!document.canUndo)
    }

    // MARK: - Selection edits

    @Test func deleteSelectionRemovesOnlySelectedAndIsUndoable() {
        let document = makeDocument()
        let keep = makeArrow()
        let drop = makeArrow()
        document.annotations = [.arrow(keep), .arrow(drop)]
        document.selectedAnnotationIds = [drop.id]

        document.deleteSelection()
        #expect(document.annotations.map(\.id) == [keep.id])
        #expect(document.selectedAnnotationIds.isEmpty)

        #expect(document.undo())
        #expect(document.annotations.count == 2)
    }

    @Test func deleteSelectionWithStaleSelectionIsANoOp() {
        let document = makeDocument()
        document.annotations = [.arrow(makeArrow())]
        document.selectedAnnotationIds = [UUID()]

        document.deleteSelection()
        #expect(document.annotations.count == 1)
        #expect(!document.canUndo)
    }

    @Test func duplicateSelectionOffsetsCopiesAndMovesSelection() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]
        document.selectedAnnotationIds = [arrow.id]

        document.duplicateSelection()

        #expect(document.annotations.count == 2)
        let copy = document.annotations[1]
        #expect(copy.id != arrow.id)
        #expect(copy.arrow?.start == CGPoint(x: 50, y: 50))
        #expect(document.selectedAnnotationIds == [copy.id])
    }

    @Test func applyColorSkipsSnapshotWhenNothingChanges() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]
        document.selectedAnnotationIds = [arrow.id]

        document.applyColorToSelection(arrow.color)
        #expect(!document.canUndo)

        document.applyColorToSelection(.purple)
        #expect(document.annotations[0].color == .purple)
        #expect(document.canUndo)
    }

    @Test func applyRectangleStyleOnlyTouchesSelectedRectangles() {
        let document = makeDocument()
        let rectangle = RectangleAnnotation(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10), color: .red, style: .outlined
        )
        let arrow = makeArrow()
        document.annotations = [.rectangle(rectangle), .arrow(arrow)]
        document.selectedAnnotationIds = [rectangle.id, arrow.id]

        document.applyRectangleStyleToSelection(.filled)
        #expect(document.annotations[0].rectangle?.style == .filled)
        #expect(document.annotations[1].arrow != nil)
    }

    // MARK: - Image edits

    @Test func applyCropShiftsAnnotationsIntoCroppedSpace() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]

        #expect(document.applyCrop(CGRect(x: 20, y: 20, width: 50, height: 50)))

        #expect(document.annotations[0].arrow?.start == CGPoint(x: 10, y: 10))
        #expect(document.annotations[0].arrow?.end == CGPoint(x: 40, y: 40))
        if let size = document.image?.size {
            #expect(approxEqual(size.width, 50, tolerance: 1))
            #expect(approxEqual(size.height, 50, tolerance: 1))
        } else {
            Issue.record("crop produced no image")
        }
        #expect(document.canUndo)
    }

    @Test func rotateImageSwapsDimensionsAndRepositionsAnnotations() {
        let document = AnnotationDocument()
        document.image = makeTestImage(width: 100, height: 50)
        let arrow = ArrowAnnotation(
            start: CGPoint(x: 10, y: 20), end: CGPoint(x: 30, y: 40), color: .red
        )
        document.annotations = [.arrow(arrow)]

        document.rotateImage(clockwise: true)

        #expect(document.image?.size == NSSize(width: 50, height: 100))
        #expect(document.annotations[0].arrow?.start == CGPoint(x: 30, y: 10))
    }

    @Test func resizeImageScalesAnnotations() {
        let document = makeDocument()
        let arrow = makeArrow()
        document.annotations = [.arrow(arrow)]

        document.resizeImage(to: NSSize(width: 200, height: 200))

        #expect(document.image?.size == NSSize(width: 200, height: 200))
        #expect(document.annotations[0].arrow?.start == CGPoint(x: 60, y: 60))
    }

    // MARK: - Save

    @Test func saveWritesPNGAndClearsDirtyFlag() throws {
        let document = makeDocument()
        document.annotations = [.arrow(makeArrow())]
        #expect(document.hasUnsavedChanges)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jiminy-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try document.save(to: url))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(document.currentFileURL == url)
        #expect(!document.hasUnsavedChanges)
    }

    @Test func saveWithoutImageReturnsFalse() throws {
        let document = AnnotationDocument()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jiminy-test-\(UUID().uuidString).png")
        #expect(try !document.save(to: url))
        #expect(document.currentFileURL == nil)
    }
}
