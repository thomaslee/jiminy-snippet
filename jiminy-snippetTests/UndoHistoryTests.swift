//
//  UndoHistoryTests.swift
//  jiminy-snippetTests
//
//  Created by Tom on 7/3/26.
//

import SwiftUI
import Testing
@testable import jiminy_snippet

struct UndoHistoryTests {
    private let image = makeTestImage()

    private func snapshot(_ annotations: [Annotation] = []) -> EditSnapshot {
        EditSnapshot(image: image, annotations: annotations)
    }

    @Test func startsEmpty() {
        let history = UndoHistory()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test func undoReturnsPushedSnapshotAndEnablesRedo() {
        var history = UndoHistory()
        let arrow = Annotation.arrow(
            ArrowAnnotation(start: .zero, end: CGPoint(x: 10, y: 10), color: .red)
        )
        history.push(snapshot([]))

        let restored = history.popUndo(current: snapshot([arrow]))
        #expect(restored?.annotations.isEmpty == true)
        #expect(history.canRedo)

        let redone = history.popRedo(current: snapshot([]))
        #expect(redone?.annotations == [arrow])
        #expect(history.canUndo)
    }

    @Test func pushClearsRedoStack() {
        var history = UndoHistory()
        history.push(snapshot())
        _ = history.popUndo(current: snapshot())
        #expect(history.canRedo)

        history.push(snapshot())
        #expect(!history.canRedo)
    }

    @Test func popUndoOnEmptyReturnsNil() {
        var history = UndoHistory()
        #expect(history.popUndo(current: snapshot()) == nil)
        // A failed undo must not seed the redo stack.
        #expect(!history.canRedo)
    }

    @Test func discardLastDropsSnapshotWithoutRedo() {
        var history = UndoHistory()
        history.push(snapshot())
        history.discardLast()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }

    @Test func capacityIsBounded() {
        var history = UndoHistory()
        for _ in 0..<(UndoHistory.maxSize + 10) {
            history.push(snapshot())
        }
        var undoCount = 0
        while history.popUndo(current: snapshot()) != nil {
            undoCount += 1
        }
        #expect(undoCount == UndoHistory.maxSize)
    }

    @Test func clearEmptiesBothStacks() {
        var history = UndoHistory()
        history.push(snapshot())
        history.push(snapshot())
        _ = history.popUndo(current: snapshot())
        history.clear()
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
