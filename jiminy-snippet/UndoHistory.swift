//
//  UndoHistory.swift
//  jiminy-snippet
//
//  Created by Tom on 4/11/26.
//

import AppKit

/// A small owned copy of a rectangular pixel region, used to undo/redo a
/// localized image edit (pixelation) without retaining the whole bitmap.
struct PixelPatch {
    /// Region in the image's bottom-left-origin pixel space.
    let pixelRect: CGRect
    /// The region's pixels. Must own its backing store (not share the source
    /// image's, as `CGImage.cropping` would) or the memory saving is lost.
    let pixels: NSImage
}

/// Snapshot of the editable state of the canvas at a single point in time.
/// Captured before each discrete edit so that the operation can later be undone.
struct EditSnapshot {
    /// The image component of the pre-edit state.
    enum ImageRecord {
        /// The full previous image. Annotation-only edits store the current
        /// image by reference (no pixel copy); crop/rotate/resize retain the
        /// genuinely different predecessor bitmap, which their undo needs.
        case whole(NSImage)
        /// The original pixels of the one region a pixelation modified,
        /// restored by stamping them back over the current image.
        case patch(PixelPatch)
    }

    let image: ImageRecord
    let annotations: [Annotation]
}

/// Fixed-capacity undo/redo history. Oldest undo snapshots are dropped once
/// the capacity is reached so memory stays bounded even across long editing
/// sessions. The redo stack is naturally bounded by the undo stack (it can
/// never grow past what was previously undone).
struct UndoHistory {
    static let maxSize = 50

    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// The snapshot the next `popUndo` / `popRedo` would return. Callers peek
    /// first to build the matching `current` record for the opposite stack —
    /// patch records need the same region captured from the current image.
    var nextUndo: EditSnapshot? { undoStack.last }
    var nextRedo: EditSnapshot? { redoStack.last }

    /// Records a pre-edit snapshot before a new mutation. Clears the redo
    /// stack because starting a fresh edit branch invalidates any pending
    /// redo path — standard undo/redo semantics.
    mutating func push(_ snapshot: EditSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.maxSize {
            undoStack.removeFirst(undoStack.count - Self.maxSize)
        }
        redoStack.removeAll()
    }

    /// Pops the most recent undo snapshot, stashing `current` on the redo
    /// stack so a subsequent `popRedo(current:)` can restore it.
    mutating func popUndo(current: EditSnapshot) -> EditSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    /// Inverse of `popUndo`. Pops the most recent redo snapshot and stashes
    /// `current` on the undo stack so another undo can step back to it.
    mutating func popRedo(current: EditSnapshot) -> EditSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    /// Drops the most recently pushed undo snapshot without recording a redo.
    /// Used when an in-flight edit (e.g. a cancelled text edit) is abandoned
    /// so its no-op snapshot doesn't burn an undo slot.
    mutating func discardLast() {
        _ = undoStack.popLast()
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
