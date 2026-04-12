//
//  ContentView.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScreenshotManager.self) private var screenshotManager

    @State private var selectedTool: AnnotationTool? = nil
    @State private var selectedColorIndex: Int = 0
    @State private var scale: CGFloat = 1.0
    @State private var canvasSize: CGSize = .zero

    @State private var arrows: [ArrowAnnotation] = []
    @State private var texts: [TextAnnotation] = []
    @State private var rectangles: [RectangleAnnotation] = []
    @State private var rectangleFillStyle: RectangleFillStyle = .outlined
    @State private var selectedAnnotationId: UUID? = nil
    @State private var cropMode: Bool = false
    @State private var cropRect: CGRect? = nil
    @State private var undoHistory = UndoHistory()

    private let scaleStep: CGFloat = 0.25
    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0

    private var selectedColor: Color {
        AnnotationPalette.colors[selectedColorIndex].color
    }

    var body: some View {
        mainContent
            .frame(minWidth: 800, minHeight: 600)
            .onChange(of: arrows) { markUnsaved() }
            .onChange(of: texts) { markUnsaved() }
            .onChange(of: rectangles) { markUnsaved() }
            .onChange(of: screenshotManager.capturedImage) {
                markUnsaved()
                zoomToFit()
            }
            .onChange(of: selectedAnnotationId) {
                syncPaletteToSelection()
            }
            .task {
                // Handles a request set by the menu bar *before* this view
                // existed (i.e. the window was closed when the user clicked
                // the menu bar item). .onChange below handles requests made
                // while the window is already open.
                handlePendingCaptureRequest()
            }
            .onChange(of: screenshotManager.pendingCaptureRequest) {
                handlePendingCaptureRequest()
            }
            .modifier(SceneCommandValues(
                hasImage: screenshotManager.capturedImage != nil,
                canZoomIn: scale < maxScale,
                canZoomOut: scale > minScale,
                canUndo: undoHistory.canUndo,
                canRedo: undoHistory.canRedo,
                canDuplicate: selectedAnnotationId != nil,
                copy: copyToClipboard,
                paste: pasteFromClipboard,
                save: save,
                saveAs: saveAs,
                zoomIn: zoomIn,
                zoomOut: zoomOut,
                zoomToFit: zoomToFit,
                zoomActualSize: zoomToActualSize,
                undo: undo,
                redo: redo,
                duplicate: duplicateSelectedAnnotation
            ))
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            if let image = screenshotManager.capturedImage {
                AnnotationCanvas(
                    image: image,
                    arrows: $arrows,
                    texts: $texts,
                    rectangles: $rectangles,
                    selectedTool: $selectedTool,
                    selectedAnnotationId: $selectedAnnotationId,
                    selectedColor: selectedColor,
                    rectangleFillStyle: rectangleFillStyle,
                    scale: $scale,
                    minScale: minScale,
                    maxScale: maxScale,
                    cropMode: cropMode,
                    cropRect: $cropRect,
                    onCropApply: applyCrop,
                    onCropCancel: cancelCrop,
                    onBeginEdit: recordSnapshot,
                    onDiscardEdit: discardLastSnapshot
                )
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { newSize in
                    let wasZero = canvasSize == .zero
                    canvasSize = newSize
                    if wasZero {
                        zoomToFit()
                    }
                }
            } else {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Take a screenshot to get started")
                .font(.title2)
                .foregroundStyle(.secondary)
            captureMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            captureMenu

            if screenshotManager.capturedImage != nil {
                Divider().frame(height: 24)
                toolPicker
                Divider().frame(height: 24)
                colorPicker
                if isRectangleContextActive {
                    Divider().frame(height: 24)
                    rectangleStyleControls
                }
                Divider().frame(height: 24)
                rotateControls
                Divider().frame(height: 24)
                cropControls
                Spacer()
                exportMenu
            }
        }
        .controlSize(.large)
    }

    private var captureMenu: some View {
        Menu {
            Button("Whole screen") {
                beginNewCapture { screenshotManager.captureFullscreen() }
            }
            Button("Screen region...") {
                beginNewCapture { screenshotManager.captureRegion() }
            }
            Menu("Screen region with delay...") {
                ForEach(timedCaptureDurations, id: \.self) { seconds in
                    Button("\(seconds) Seconds") {
                        beginNewCapture {
                            screenshotManager.captureRegionAfterDelay(seconds: seconds)
                        }
                    }
                }
            }
            Button("Clipboard") {
                pasteFromClipboard()
            }
        } label: {
            Label("Capture", systemImage: "camera")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Capture a new screenshot")
    }

    /// Preset durations offered in the "Timed screen snap" submenu. 5 seconds
    /// is the default (first entry a user is likely to reach for).
    private var timedCaptureDurations: [Int] { [3, 5, 10] }

    /// Consumes any pending capture request left by the menu bar item.
    /// Dispatches through the same helpers the in-app capture menu uses, so
    /// the unsaved-changes confirmation and annotation clearing logic stay in
    /// a single place regardless of where the request originated.
    private func handlePendingCaptureRequest() {
        guard let request = screenshotManager.pendingCaptureRequest else { return }
        screenshotManager.pendingCaptureRequest = nil

        switch request {
        case .fullscreen:
            beginNewCapture { screenshotManager.captureFullscreen() }
        case .region:
            beginNewCapture { screenshotManager.captureRegion() }
        case .timed(let seconds):
            beginNewCapture {
                screenshotManager.captureRegionAfterDelay(seconds: seconds)
            }
        case .fromClipboard:
            pasteFromClipboard()
        }
    }

    /// Prompts the user to discard unsaved changes (if any) and, on
    /// confirmation, clears existing annotations and runs `capture`.
    private func beginNewCapture(_ capture: () -> Void) {
        guard confirmDiscardIfNeeded(
            messageText: "You have unsaved changes",
            informativeText: "Taking a new screenshot will discard your current edits. Continue?",
            proceedButtonTitle: "Continue"
        ) else { return }
        // Abort any pending timed capture so switching capture modes mid-
        // countdown restores the Jiminy window before the new action runs.
        screenshotManager.cancelTimedCapture()
        clearAnnotations()
        capture()
    }

    private func confirmDiscardIfNeeded(
        messageText: String,
        informativeText: String,
        proceedButtonTitle: String
    ) -> Bool {
        guard screenshotManager.hasUnsavedChanges else { return true }
        return ScreenshotManager.confirmDiscardUnsavedChanges(
            messageText: messageText,
            informativeText: informativeText,
            proceedButtonTitle: proceedButtonTitle
        )
    }

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Button {
                    selectedTool = selectedTool == tool ? nil : tool
                } label: {
                    Image(systemName: tool.systemImage)
                }
                .buttonStyle(.bordered)
                .tint(selectedTool == tool ? .accentColor : nil)
                .help(tool.helpText)
            }
        }
    }

    private var colorPicker: some View {
        Menu {
            ForEach(Array(AnnotationPalette.colors.enumerated()), id: \.offset) { index, item in
                Button {
                    selectColor(at: index)
                } label: {
                    Image(nsImage: Self.swatchImage(for: item.color))
                    Text(index == selectedColorIndex ? "✓" : " ")
                }
            }
        } label: {
            Image(nsImage: Self.swatchImage(for: selectedColor, size: 16))
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Annotation color: \(AnnotationPalette.colors[selectedColorIndex].name)")
    }

    private static func swatchImage(for color: Color, size: CGFloat = 14) -> NSImage {
        let nsColor = NSColor(color)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1, dy: 1)
            nsColor.setFill()
            NSBezierPath(ovalIn: inset).fill()
            NSColor.gray.withAlphaComponent(0.5).setStroke()
            let stroke = NSBezierPath(ovalIn: inset)
            stroke.lineWidth = 1
            stroke.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func selectColor(at index: Int) {
        selectedColorIndex = index
        let color = AnnotationPalette.colors[index].color
        guard let id = selectedAnnotationId else { return }
        if let i = arrows.firstIndex(where: { $0.id == id }) {
            guard arrows[i].color != color else { return }
            recordSnapshot()
            arrows[i].color = color
        } else if let i = texts.firstIndex(where: { $0.id == id }) {
            guard texts[i].color != color else { return }
            recordSnapshot()
            texts[i].color = color
        } else if let i = rectangles.firstIndex(where: { $0.id == id }) {
            guard rectangles[i].color != color else { return }
            recordSnapshot()
            rectangles[i].color = color
        }
    }

    /// Whether the rectangle style toggle should be visible — either the
    /// rectangle tool is selected (so the choice affects the next draw) or a
    /// rectangle annotation is currently selected (so the choice edits it in
    /// place).
    private var isRectangleContextActive: Bool {
        if selectedTool == .rectangle { return true }
        guard let id = selectedAnnotationId else { return false }
        return rectangles.contains(where: { $0.id == id })
    }

    private var rectangleStyleControls: some View {
        HStack(spacing: 4) {
            Button {
                setRectangleFillStyle(.outlined)
            } label: {
                Image(systemName: "rectangle")
            }
            .buttonStyle(.bordered)
            .tint(rectangleFillStyle == .outlined ? .accentColor : nil)
            .help("Outlined rectangle")

            Button {
                setRectangleFillStyle(.filled)
            } label: {
                Image(systemName: "rectangle.fill")
            }
            .buttonStyle(.bordered)
            .tint(rectangleFillStyle == .filled ? .accentColor : nil)
            .help("Filled rectangle")
        }
    }

    /// Picks a fill style for future rectangle draws and, if a rectangle is
    /// currently selected, applies the style to it in place (undoable).
    private func setRectangleFillStyle(_ style: RectangleFillStyle) {
        rectangleFillStyle = style
        guard let id = selectedAnnotationId,
              let i = rectangles.firstIndex(where: { $0.id == id }),
              rectangles[i].style != style
        else { return }
        recordSnapshot()
        rectangles[i].style = style
    }

    private var rotateControls: some View {
        HStack(spacing: 4) {
            Button {
                rotateImageAndAnnotations(clockwise: false)
            } label: {
                Image(systemName: "rotate.left")
            }
            .help("Rotate counter-clockwise")

            Button {
                rotateImageAndAnnotations(clockwise: true)
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("Rotate clockwise")
        }
    }

    private var cropControls: some View {
        Button {
            toggleCropMode()
        } label: {
            Image(systemName: "crop")
        }
        .buttonStyle(.bordered)
        .tint(cropMode ? .accentColor : nil)
        .help(cropMode ? "Exit crop mode" : "Crop image")
    }

    private var exportMenu: some View {
        Menu {
            Button("Save") {
                save()
            }
            Button("Save As...") {
                saveAs()
            }
            Button("Copy to Clipboard") {
                copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Save or copy the annotated image")
    }

    private func syncPaletteToSelection() {
        guard let id = selectedAnnotationId else { return }
        let color: Color
        if let arrow = arrows.first(where: { $0.id == id }) {
            color = arrow.color
        } else if let text = texts.first(where: { $0.id == id }) {
            color = text.color
        } else if let rectangle = rectangles.first(where: { $0.id == id }) {
            color = rectangle.color
            // Sync the style toggle so the toolbar reflects the selection.
            rectangleFillStyle = rectangle.style
        } else {
            return
        }
        if let index = AnnotationPalette.colors.firstIndex(where: { $0.color == color }) {
            selectedColorIndex = index
        }
    }

    private func clearAnnotations() {
        arrows.removeAll()
        texts.removeAll()
        rectangles.removeAll()
        undoHistory.clear()
    }

    /// Captures the current editable state so that the next mutation can be
    /// undone. Called by the canvas at the start of every discrete edit (drag,
    /// text create/edit, delete) and directly from ContentView for crop,
    /// rotate, and color changes.
    private func recordSnapshot() {
        guard let image = screenshotManager.capturedImage else { return }
        undoHistory.push(
            EditSnapshot(image: image, arrows: arrows, texts: texts, rectangles: rectangles)
        )
    }

    /// Drops the most recently pushed snapshot. Used when an in-flight edit is
    /// abandoned (e.g. text editing is cancelled) so cancelled operations don't
    /// leave no-op entries on the stack.
    private func discardLastSnapshot() {
        undoHistory.discardLast()
    }

    /// Duplicates the currently selected annotation, offsetting the copy so the
    /// user can see it landed on top of the original. Selection moves to the
    /// new copy so repeated invocations stack diagonally.
    private func duplicateSelectedAnnotation() {
        guard let id = selectedAnnotationId else { return }
        let offset = CGSize(width: 20, height: 20)
        if let arrow = arrows.first(where: { $0.id == id }) {
            recordSnapshot()
            let copy = arrow.duplicated(offset: offset)
            arrows.append(copy)
            selectedAnnotationId = copy.id
        } else if let text = texts.first(where: { $0.id == id }) {
            recordSnapshot()
            let copy = text.duplicated(offset: offset)
            texts.append(copy)
            selectedAnnotationId = copy.id
        } else if let rectangle = rectangles.first(where: { $0.id == id }) {
            recordSnapshot()
            let copy = rectangle.duplicated(offset: offset)
            rectangles.append(copy)
            selectedAnnotationId = copy.id
        }
    }

    private func undo() {
        guard let current = currentEditSnapshot(),
              let previous = undoHistory.popUndo(current: current)
        else { return }
        apply(snapshot: previous)
    }

    private func redo() {
        guard let current = currentEditSnapshot(),
              let next = undoHistory.popRedo(current: current)
        else { return }
        apply(snapshot: next)
    }

    /// Snapshot of the current editable state, used by undo/redo to stash the
    /// "before" state onto the opposite stack. Returns nil if there's no image
    /// loaded — in which case there's nothing to undo anyway.
    private func currentEditSnapshot() -> EditSnapshot? {
        guard let image = screenshotManager.capturedImage else { return nil }
        return EditSnapshot(
            image: image, arrows: arrows, texts: texts, rectangles: rectangles
        )
    }

    /// Restores a snapshot produced by undo or redo. Clears selection and
    /// exits crop mode because both become meaningless against the restored
    /// state.
    private func apply(snapshot: EditSnapshot) {
        arrows = snapshot.arrows
        texts = snapshot.texts
        rectangles = snapshot.rectangles
        if screenshotManager.capturedImage !== snapshot.image {
            screenshotManager.capturedImage = snapshot.image
        }
        selectedAnnotationId = nil
        if cropMode {
            cancelCrop()
        }
    }

    private func pasteFromClipboard() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else { return }
        guard confirmDiscardIfNeeded(
            messageText: "You have unsaved changes",
            informativeText: "Pasting from the clipboard will discard your current edits. Continue?",
            proceedButtonTitle: "Continue"
        ) else { return }
        clearAnnotations()
        screenshotManager.capturedImage = image
        // markUnsaved() and zoomToFit() are handled by onChange observers
    }

    private func copyToClipboard() {
        guard let image = screenshotManager.capturedImage else { return }

        let rendered = ImageExporter.render(
            image: image,
            arrows: arrows,
            texts: texts,
            rectangles: rectangles
        )

        ImageExporter.copyToPasteboard(image: rendered)
    }

    private func save() {
        if let url = screenshotManager.currentFileURL {
            writeCurrentImage(to: url)
        } else {
            saveAs()
        }
    }

    private func saveAs() {
        guard screenshotManager.capturedImage != nil else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = screenshotManager.currentFileURL?.lastPathComponent ?? "screenshot.png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCurrentImage(to: url)
    }

    private func writeCurrentImage(to url: URL) {
        guard let image = screenshotManager.capturedImage else { return }

        let rendered = ImageExporter.render(
            image: image,
            arrows: arrows,
            texts: texts,
            rectangles: rectangles
        )

        do {
            try ImageExporter.save(image: rendered, to: url)
            screenshotManager.currentFileURL = url
            screenshotManager.hasUnsavedChanges = false
        } catch {
            presentSaveError(url: url, error: error)
        }
    }

    private func presentSaveError(url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Save “\(url.lastPathComponent)”"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func zoomIn() {
        scale = min(maxScale, scale + scaleStep)
    }

    private func zoomOut() {
        scale = max(minScale, scale - scaleStep)
    }

    private func zoomToActualSize() {
        scale = 1.0
    }

    private func zoomToFit() {
        guard let image = screenshotManager.capturedImage else { return }
        let availableSize = canvasSize
        guard availableSize.width > 0, availableSize.height > 0 else { return }

        let imageSize = image.size
        let scaleX = availableSize.width / imageSize.width
        let scaleY = availableSize.height / imageSize.height
        let fitScale = min(scaleX, scaleY)
        scale = clamp(min(fitScale, 1.0), min: minScale, max: maxScale)
    }

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.min(hi, Swift.max(lo, value))
    }

    private func toggleCropMode() {
        if cropMode {
            cancelCrop()
        } else {
            cropMode = true
            cropRect = nil
            selectedAnnotationId = nil
            selectedTool = nil
        }
    }

    private func cancelCrop() {
        cropMode = false
        cropRect = nil
    }

    private func applyCrop() {
        guard let rect = cropRect,
              let image = screenshotManager.capturedImage,
              let cropped = image.cropped(to: rect)
        else {
            cancelCrop()
            return
        }

        recordSnapshot()

        let dx = -rect.origin.x
        let dy = -rect.origin.y
        for i in arrows.indices {
            arrows[i].start.x += dx
            arrows[i].start.y += dy
            arrows[i].end.x += dx
            arrows[i].end.y += dy
        }
        for i in texts.indices {
            texts[i].position.x += dx
            texts[i].position.y += dy
        }
        for i in rectangles.indices {
            rectangles[i].rect = rectangles[i].rect.offsetBy(dx: dx, dy: dy)
        }

        selectedAnnotationId = nil
        screenshotManager.capturedImage = cropped
        cropMode = false
        cropRect = nil
        // markUnsaved() and zoomToFit() are handled by onChange observers
    }

    private func rotateImageAndAnnotations(clockwise: Bool) {
        guard let image = screenshotManager.capturedImage else { return }
        recordSnapshot()
        let w = image.size.width
        let h = image.size.height

        screenshotManager.capturedImage = image.rotated(clockwise: clockwise)

        for i in arrows.indices {
            arrows[i].start = rotatePoint(arrows[i].start, imageWidth: w, imageHeight: h, clockwise: clockwise)
            arrows[i].end = rotatePoint(arrows[i].end, imageWidth: w, imageHeight: h, clockwise: clockwise)
        }
        for i in texts.indices {
            texts[i].position = rotatePoint(texts[i].position, imageWidth: w, imageHeight: h, clockwise: clockwise)
            texts[i].rotation += clockwise ? 90 : -90
        }
        for i in rectangles.indices {
            let standardized = rectangles[i].rect.standardized
            let p1 = rotatePoint(
                CGPoint(x: standardized.minX, y: standardized.minY),
                imageWidth: w, imageHeight: h, clockwise: clockwise
            )
            let p2 = rotatePoint(
                CGPoint(x: standardized.maxX, y: standardized.maxY),
                imageWidth: w, imageHeight: h, clockwise: clockwise
            )
            rectangles[i].rect = CGRect(
                x: min(p1.x, p2.x),
                y: min(p1.y, p2.y),
                width: abs(p2.x - p1.x),
                height: abs(p2.y - p1.y)
            )
        }

        selectedAnnotationId = nil
        // zoomToFit() and markUnsaved() are handled by onChange observers
    }

    private func rotatePoint(_ point: CGPoint, imageWidth w: CGFloat, imageHeight h: CGFloat, clockwise: Bool) -> CGPoint {
        if clockwise {
            return CGPoint(x: h - point.y, y: point.x)
        } else {
            return CGPoint(x: point.y, y: w - point.x)
        }
    }

    private func markUnsaved() {
        if screenshotManager.capturedImage != nil {
            screenshotManager.hasUnsavedChanges = true
        }
    }
}

/// Publishes the view's scene-level command actions via `focusedSceneValue`.
/// Extracted into a separate modifier so the main `body` stays under the
/// Swift type-checker's complexity budget as more commands are added.
private struct SceneCommandValues: ViewModifier {
    let hasImage: Bool
    let canZoomIn: Bool
    let canZoomOut: Bool
    let canUndo: Bool
    let canRedo: Bool
    let canDuplicate: Bool
    let copy: () -> Void
    let paste: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomToFit: () -> Void
    let zoomActualSize: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let duplicate: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(fileAndClipboardValues)
            .modifier(zoomValues)
            .focusedSceneValue(\.undoScene, canUndo ? undo : nil)
            .focusedSceneValue(\.redoScene, canRedo ? redo : nil)
            .focusedSceneValue(\.duplicateScene, canDuplicate ? duplicate : nil)
    }

    private var fileAndClipboardValues: some ViewModifier {
        FileAndClipboardSceneValues(
            hasImage: hasImage,
            copy: copy, paste: paste, save: save, saveAs: saveAs
        )
    }

    private var zoomValues: some ViewModifier {
        ZoomSceneValues(
            hasImage: hasImage,
            canZoomIn: canZoomIn,
            canZoomOut: canZoomOut,
            zoomIn: zoomIn,
            zoomOut: zoomOut,
            zoomToFit: zoomToFit,
            zoomActualSize: zoomActualSize
        )
    }
}

private struct FileAndClipboardSceneValues: ViewModifier {
    let hasImage: Bool
    let copy: () -> Void
    let paste: () -> Void
    let save: () -> Void
    let saveAs: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.copyScene, hasImage ? copy : nil)
            .focusedSceneValue(\.pasteScene, paste)
            .focusedSceneValue(\.saveScene, hasImage ? save : nil)
            .focusedSceneValue(\.saveAsScene, hasImage ? saveAs : nil)
    }
}

private struct ZoomSceneValues: ViewModifier {
    let hasImage: Bool
    let canZoomIn: Bool
    let canZoomOut: Bool
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomToFit: () -> Void
    let zoomActualSize: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.zoomInScene, (hasImage && canZoomIn) ? zoomIn : nil)
            .focusedSceneValue(\.zoomOutScene, (hasImage && canZoomOut) ? zoomOut : nil)
            .focusedSceneValue(\.zoomToFitScene, hasImage ? zoomToFit : nil)
            .focusedSceneValue(\.zoomActualSizeScene, hasImage ? zoomActualSize : nil)
    }
}

#Preview {
    ContentView()
        .environment(ScreenshotManager())
}
