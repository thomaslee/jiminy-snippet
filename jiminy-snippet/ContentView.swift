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
            .onChange(of: screenshotManager.capturedImage) {
                markUnsaved()
                zoomToFit()
            }
            .onChange(of: selectedAnnotationId) {
                syncPaletteToSelection()
            }
            .modifier(SceneCommandValues(
                hasImage: screenshotManager.capturedImage != nil,
                canZoomIn: scale < maxScale,
                canZoomOut: scale > minScale,
                canUndo: !undoHistory.isEmpty,
                copy: copyToClipboard,
                paste: pasteFromClipboard,
                save: save,
                saveAs: saveAs,
                zoomIn: zoomIn,
                zoomOut: zoomOut,
                zoomToFit: zoomToFit,
                zoomActualSize: zoomToActualSize,
                undo: undo
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
                    selectedTool: $selectedTool,
                    selectedAnnotationId: $selectedAnnotationId,
                    selectedColor: selectedColor,
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
                Divider().frame(height: 24)
                rotateControls
                Divider().frame(height: 24)
                cropControls
                Spacer()
                exportMenu
                undoButton
            }
        }
        .controlSize(.large)
    }

    private var captureMenu: some View {
        Menu {
            Button("Fullscreen") {
                beginNewCapture { screenshotManager.captureFullscreen() }
            }
            Button("Screen snap...") {
                beginNewCapture { screenshotManager.captureRegion() }
            }
            Button("From Clipboard") {
                pasteFromClipboard()
            }
            Button("Timed screen snap...") {
                // Not implemented
            }
            .disabled(true)
        } label: {
            Label("Capture", systemImage: "camera")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Capture a new screenshot")
    }

    /// Prompts the user to discard unsaved changes (if any) and, on
    /// confirmation, clears existing annotations and runs `capture`.
    private func beginNewCapture(_ capture: () -> Void) {
        guard confirmDiscardIfNeeded(
            messageText: "You have unsaved changes",
            informativeText: "Taking a new screenshot will discard your current edits. Continue?",
            proceedButtonTitle: "Continue"
        ) else { return }
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
        }
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

    private var undoButton: some View {
        Button {
            undo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .help("Undo last edit")
        .disabled(undoHistory.isEmpty)
    }

    private func syncPaletteToSelection() {
        guard let id = selectedAnnotationId else { return }
        let color: Color
        if let arrow = arrows.first(where: { $0.id == id }) {
            color = arrow.color
        } else if let text = texts.first(where: { $0.id == id }) {
            color = text.color
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
        undoHistory.clear()
    }

    /// Captures the current editable state so that the next mutation can be
    /// undone. Called by the canvas at the start of every discrete edit (drag,
    /// text create/edit, delete) and directly from ContentView for crop,
    /// rotate, and color changes.
    private func recordSnapshot() {
        guard let image = screenshotManager.capturedImage else { return }
        undoHistory.push(
            EditSnapshot(image: image, arrows: arrows, texts: texts)
        )
    }

    /// Drops the most recently pushed snapshot. Used when an in-flight edit is
    /// abandoned (e.g. text editing is cancelled) so cancelled operations don't
    /// leave no-op entries on the stack.
    private func discardLastSnapshot() {
        _ = undoHistory.pop()
    }

    private func undo() {
        guard let snapshot = undoHistory.pop() else { return }
        arrows = snapshot.arrows
        texts = snapshot.texts
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
            texts: texts
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
            texts: texts
        )

        if ImageExporter.save(image: rendered, to: url) {
            screenshotManager.currentFileURL = url
            screenshotManager.hasUnsavedChanges = false
        }
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
    let copy: () -> Void
    let paste: () -> Void
    let save: () -> Void
    let saveAs: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomToFit: () -> Void
    let zoomActualSize: () -> Void
    let undo: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(fileAndClipboardValues)
            .modifier(zoomValues)
            .focusedSceneValue(\.undoScene, canUndo ? undo : nil)
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
