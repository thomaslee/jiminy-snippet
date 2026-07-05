//
//  AnnotationDocument.swift
//  jiminy-snippet
//
//  Created by Tom on 7/3/26.
//

import AppKit
import Observation
import SwiftUI

/// The editable state of the current screenshot — the image, its annotations,
/// the selection, undo history, and backing-file status — plus the discrete
/// edit operations views invoke on it. Owning all of this in one observable
/// object keeps the views thin and makes the edit logic testable without
/// going through SwiftUI.
@Observable
@MainActor
final class AnnotationDocument {
    /// The screenshot being edited. Mutated in place by destructive image
    /// operations (crop, rotate, resize, pixelate) and swapped wholesale when
    /// a new capture or paste is adopted via `loadImage`.
    var image: NSImage? {
        didSet { if image != nil { hasUnsavedChanges = true } }
    }

    var annotations: [Annotation] = [] {
        didSet { if image != nil { hasUnsavedChanges = true } }
    }

    var selectedAnnotationIds: Set<UUID> = []

    /// URL of the file backing the current screenshot, if it has been saved.
    /// Reset to `nil` whenever a new image is loaded from a fresh source
    /// (capture, paste) — but preserved through in-place edits like crop and
    /// rotate so that Save can overwrite the existing file.
    var currentFileURL: URL?

    var hasUnsavedChanges = false

    private var undoHistory = UndoHistory()

    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }

    // MARK: - Loading

    /// Adopts a new source image (fresh capture or paste), dropping all
    /// annotations, selection, and undo history.
    func loadImage(_ newImage: NSImage) {
        annotations.removeAll()
        selectedAnnotationIds.removeAll()
        undoHistory.clear()
        image = newImage
    }

    // MARK: - Undo

    /// Captures the current editable state so that the next mutation can be
    /// undone. Called at the start of every discrete edit — by the canvas for
    /// gesture-driven edits, and internally by the document's own operations.
    func recordSnapshot() {
        guard let image else { return }
        undoHistory.push(EditSnapshot(image: .whole(image), annotations: annotations))
    }

    /// Drops the most recently pushed snapshot. Used when an in-flight edit is
    /// abandoned (e.g. text editing is cancelled) so cancelled operations don't
    /// leave no-op entries on the stack.
    func discardLastSnapshot() {
        undoHistory.discardLast()
    }

    /// Steps back to the previous snapshot. Returns false when there is
    /// nothing to undo.
    @discardableResult
    func undo() -> Bool {
        guard let record = undoHistory.nextUndo,
              let restored = state(restoring: record),
              let counterpart = counterpart(of: record)
        else { return false }
        _ = undoHistory.popUndo(current: counterpart)
        apply(image: restored.image, annotations: restored.annotations)
        return true
    }

    /// Inverse of `undo`. Returns false when there is nothing to redo.
    @discardableResult
    func redo() -> Bool {
        guard let record = undoHistory.nextRedo,
              let restored = state(restoring: record),
              let counterpart = counterpart(of: record)
        else { return false }
        _ = undoHistory.popRedo(current: counterpart)
        apply(image: restored.image, annotations: restored.annotations)
        return true
    }

    /// The full editable state a record restores. Whole-image records carry
    /// it directly; patch records rebuild the previous image by stamping the
    /// saved pixels over the current one. Resolved before touching the
    /// stacks so a failure can't leave history half-popped.
    private func state(
        restoring record: EditSnapshot
    ) -> (image: NSImage, annotations: [Annotation])? {
        guard let image else { return nil }
        switch record.image {
        case .whole(let previous):
            return (previous, record.annotations)
        case .patch(let patch):
            guard let restored = image.stampingPatch(patch.pixels, at: patch.pixelRect)
            else { return nil }
            return (restored, record.annotations)
        }
    }

    /// The record for the opposite stack that reverses `record`. Mirrors the
    /// record's shape: whole-image records stash the current image by
    /// reference; patch records capture the same region's current pixels, so
    /// both directions of a pixelation stay patch-sized.
    private func counterpart(of record: EditSnapshot) -> EditSnapshot? {
        guard let image else { return nil }
        switch record.image {
        case .whole:
            return EditSnapshot(image: .whole(image), annotations: annotations)
        case .patch(let patch):
            guard let pixels = image.pixelPatch(in: patch.pixelRect) else { return nil }
            return EditSnapshot(
                image: .patch(PixelPatch(pixelRect: patch.pixelRect, pixels: pixels)),
                annotations: annotations
            )
        }
    }

    /// Applies a state produced by undo or redo. Clears selection because it
    /// becomes meaningless against the restored state.
    private func apply(image newImage: NSImage, annotations newAnnotations: [Annotation]) {
        annotations = newAnnotations
        if image !== newImage {
            image = newImage
        }
        selectedAnnotationIds.removeAll()
    }

    // MARK: - Selection Edits

    /// Deletes every selected annotation (undoable). No-op when nothing in
    /// the selection still exists.
    func deleteSelection() {
        let ids = selectedAnnotationIds
        guard annotations.contains(where: { ids.contains($0.id) }) else { return }
        recordSnapshot()
        annotations.removeAll { ids.contains($0.id) }
        selectedAnnotationIds.removeAll()
    }

    /// Duplicates every selected annotation, offsetting each copy so the user
    /// can see it landed on top of the original. Selection moves to the new
    /// copies so repeated invocations stack diagonally.
    func duplicateSelection() {
        let offset = CGSize(width: 20, height: 20)
        let toDuplicate = annotations.filter { selectedAnnotationIds.contains($0.id) }
        guard !toDuplicate.isEmpty else { return }

        recordSnapshot()

        var newSelection: Set<UUID> = []
        for annotation in toDuplicate {
            let copy = annotation.duplicated(offset: offset)
            annotations.append(copy)
            newSelection.insert(copy.id)
        }
        selectedAnnotationIds = newSelection
    }

    /// Applies `color` to every selected annotation (undoable). No-op when
    /// the selection is empty or already uniformly that color.
    func applyColorToSelection(_ color: Color) {
        let ids = selectedAnnotationIds
        guard !ids.isEmpty else { return }
        guard annotations.contains(where: { ids.contains($0.id) && $0.color != color }) else {
            return
        }

        recordSnapshot()
        for i in annotations.indices where ids.contains(annotations[i].id) {
            annotations[i].color = color
        }
    }

    /// Applies `style` to every selected rectangle (undoable). No-op when the
    /// selection contains no rectangle that would change.
    func applyRectangleStyleToSelection(_ style: RectangleFillStyle) {
        let ids = selectedAnnotationIds
        let needsChange = annotations.contains {
            ids.contains($0.id) && $0.rectangle.map { $0.style != style } == true
        }
        guard needsChange else { return }

        recordSnapshot()
        for id in ids {
            annotations.updateRectangle(id: id) { $0.style = style }
        }
    }

    // MARK: - Image Edits

    /// Crops the image to `rect` (image point space), shifting annotations so
    /// they stay over the same content. Returns false when the crop can't be
    /// applied.
    @discardableResult
    func applyCrop(_ rect: CGRect) -> Bool {
        guard let image, let cropped = image.cropped(to: rect) else { return false }

        recordSnapshot()

        let offset = CGSize(width: -rect.origin.x, height: -rect.origin.y)
        annotations = annotations.map { $0.translated(by: offset) }

        selectedAnnotationIds.removeAll()
        self.image = cropped
        return true
    }

    /// Rotates the image by 90°, repositioning annotations to match.
    func rotateImage(clockwise: Bool) {
        guard let image, let rotated = image.rotated(clockwise: clockwise) else { return }
        recordSnapshot()
        let w = image.size.width
        let h = image.size.height

        self.image = rotated
        annotations = annotations.map {
            $0.rotated90(clockwise: clockwise, imageWidth: w, imageHeight: h)
        }
        selectedAnnotationIds.removeAll()
    }

    /// Resizes the image to `newSize` (in points), scaling annotations to
    /// keep them over the same content.
    func resizeImage(to newSize: NSSize) {
        guard let image, let resized = image.resized(to: newSize) else { return }
        let oldSize = image.size
        guard oldSize.width > 0, oldSize.height > 0 else { return }

        recordSnapshot()

        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height
        annotations = annotations.map { $0.scaled(sx: sx, sy: sy) }

        selectedAnnotationIds.removeAll()
        self.image = resized
    }

    /// Applies a destructive pixelation to the image, replacing the rect's
    /// pixels with their pixelated equivalents. Records its own patch-sized
    /// undo entry: only the affected region's original pixels are retained,
    /// not the whole predecessor bitmap. Drops selection so the user reacts
    /// to the redacted image rather than carrying selection state from the
    /// pre-redaction view.
    func applyPixelation(rect: CGRect) {
        guard let image,
              let region = image.pixelationBounds(for: rect),
              let originals = image.pixelPatch(in: region),
              let updated = image.pixelating(
                  rect: rect, blockSize: PixelateDefaults.blockSize(for: image.size)
              )
        else { return }
        undoHistory.push(EditSnapshot(
            image: .patch(PixelPatch(pixelRect: region, pixels: originals)),
            annotations: annotations
        ))
        self.image = updated
        selectedAnnotationIds.removeAll()
    }

    // MARK: - Export

    /// The image with all annotations burned in, ready for export. Nil when
    /// no image is loaded.
    func renderedImage() -> NSImage? {
        guard let image else { return nil }
        return ImageExporter.render(image: image, annotations: annotations)
    }

    /// Renders and writes a PNG to `url`, updating the backing-file status on
    /// success. Returns false when there is no image to save.
    @discardableResult
    func save(to url: URL) throws -> Bool {
        guard let rendered = renderedImage() else { return false }
        try ImageExporter.save(image: rendered, to: url)
        currentFileURL = url
        hasUnsavedChanges = false
        return true
    }
}
