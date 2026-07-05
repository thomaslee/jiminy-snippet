//
//  ContentView.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(CaptureService.self) private var captureService
    @Environment(AnnotationDocument.self) private var document

    @State private var selectedTool: AnnotationTool? = nil
    @State private var selectedColorIndex: Int = 0
    @State private var scale: CGFloat = 1.0
    @State private var canvasSize: CGSize = .zero

    @State private var rectangleFillStyle: RectangleFillStyle = .outlined
    @State private var cropMode: Bool = false
    @State private var cropRect: CGRect? = nil
    /// Pre-pixelated copy of the current image, regenerated when the
    /// underlying image changes (new capture, crop, rotate, resize, pixelate
    /// commit). Used as the live preview while the user drags the destructive
    /// pixelate tool.
    @State private var pixelatedImage: NSImage?
    @State private var toast: ExportToast?
    @State private var toastDismissTask: Task<Void, Never>?

    private let scaleStep: CGFloat = 0.25
    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0

    private var selectedColor: Color {
        AnnotationPalette.colors[selectedColorIndex].color
    }

    var body: some View {
        mainContent
            .frame(minWidth: 800, minHeight: 600)
            .onChange(of: document.image) { oldImage, newImage in
                // Re-fit only when the image dimensions actually change
                // (crop/resize/rotate/new-capture). A same-size swap — e.g.
                // committing a pixelate — keeps the user's current zoom.
                if oldImage?.size != newImage?.size {
                    zoomToFit()
                }
                // The cached pixelate preview no longer matches the image.
                // Drop it rather than eagerly recomputing, so edits that
                // never use the pixelate tool don't pay for a full-image
                // CIPixellate. Rebuilt immediately only if the tool is
                // active right now (e.g. undo while mid-redaction).
                pixelatedImage = nil
                if selectedTool == .pixelate {
                    regeneratePixelatedImage()
                }
            }
            .onChange(of: selectedTool) {
                if selectedTool == .pixelate, pixelatedImage == nil {
                    regeneratePixelatedImage()
                }
            }
            .onChange(of: document.selectedAnnotationIds) {
                syncPaletteToSelection()
            }
            .task {
                // Handles a request set by the menu bar *before* this view
                // existed (i.e. the window was closed when the user clicked
                // the menu bar item). .onChange below handles requests made
                // while the window is already open.
                handlePendingCaptureRequest()
            }
            .onChange(of: captureService.pendingCaptureRequest) {
                handlePendingCaptureRequest()
            }
            .modifier(SceneCommandValues(
                hasImage: document.image != nil,
                canZoomIn: scale < maxScale,
                canZoomOut: scale > minScale,
                canUndo: document.canUndo,
                canRedo: document.canRedo,
                canDuplicate: !document.selectedAnnotationIds.isEmpty,
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
                duplicate: document.duplicateSelection
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

            if let image = document.image {
                AnnotationCanvas(
                    image: image,
                    pixelatedImage: pixelatedImage,
                    selectedTool: $selectedTool,
                    selectedColor: selectedColor,
                    rectangleFillStyle: rectangleFillStyle,
                    scale: $scale,
                    minScale: minScale,
                    maxScale: maxScale,
                    cropMode: $cropMode,
                    cropRect: $cropRect,
                    onCropApply: applyCrop,
                    onCropCancel: cancelCrop
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
                Divider()
                statusBar(for: image)
            } else {
                emptyState
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                ExportToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom))
                    )
                    .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
    }

    /// Bottom-edge status bar showing the current image's pixel dimensions.
    /// Pixel dimensions (not point dimensions) match what users expect for
    /// screenshots — a Retina capture reads as e.g. 2880×1800, not 1440×900.
    private func statusBar(for image: NSImage) -> some View {
        let dimensions = pixelDimensions(of: image)
        return HStack {
            Spacer()
            Text("\(dimensions.width) × \(dimensions.height) px")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func pixelDimensions(of image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first(where: { $0.pixelsWide > 0 }) {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
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
            if document.image != nil {
                captureMenu
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
                resizeControls
                Spacer()
                exportMenu
            }
        }
        .controlSize(.large)
    }

    private var captureMenu: some View {
        Menu {
            Button("Whole screen") {
                beginNewCapture { try await captureService.captureFullscreen() }
            }
            .help("Capture the entire screen")
            Button("Screen region...") {
                beginNewCapture { try await captureService.captureRegion() }
            }
            .help("Drag to capture a rectangular region of the screen")
            Menu("Screen region with delay...") {
                ForEach(timedCaptureDurations, id: \.self) { seconds in
                    Button("\(seconds) Seconds") {
                        beginNewCapture {
                            try await captureService.captureRegionAfterDelay(seconds: seconds)
                        }
                    }
                    .help("Capture a screen region after a \(seconds)-second delay")
                }
            }
            .help("Capture a screen region after a countdown")
            Button("Clipboard") {
                pasteFromClipboard()
            }
            .help("Paste an image from the clipboard (⌘V)")
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
        guard let request = captureService.pendingCaptureRequest else { return }
        captureService.pendingCaptureRequest = nil

        switch request {
        case .fullscreen:
            beginNewCapture { try await captureService.captureFullscreen() }
        case .region:
            beginNewCapture { try await captureService.captureRegion() }
        case .timed(let seconds):
            beginNewCapture {
                try await captureService.captureRegionAfterDelay(seconds: seconds)
            }
        case .fromClipboard:
            pasteFromClipboard()
        }
    }

    /// Starts a capture flow and adopts its result. A nil result means the
    /// user cancelled (Escape during selection or the countdown) — existing
    /// edits stay untouched, which is also why the unsaved-changes prompt is
    /// deferred until a capture has actually been acquired.
    private func beginNewCapture(_ capture: @escaping () async throws -> NSImage?) {
        // Abort any pending timed capture so switching capture modes mid-
        // countdown restores the Jiminy window before the new action runs.
        captureService.cancelTimedCapture()
        Task {
            do {
                guard let image = try await capture() else { return }
                adoptCapture(image)
            } catch {
                presentCaptureFailure(error.localizedDescription)
            }
        }
    }

    /// Adopts a freshly-acquired capture, prompting the user to discard
    /// unsaved edits first if necessary. If the user declines, the new image
    /// is dropped and existing edits are preserved.
    private func adoptCapture(_ image: NSImage) {
        guard confirmDiscardIfNeeded(
            messageText: "You have unsaved changes",
            informativeText: "Taking a new screenshot will discard your current edits. Continue?",
            proceedButtonTitle: "Continue"
        ) else { return }
        document.currentFileURL = nil
        document.loadImage(image)
    }

    /// Surfaces a capture failure as a toast when the editor window is on
    /// screen, or as an `NSAlert` when it isn't (e.g. a menu-bar triggered
    /// capture that failed before the window finished opening).
    private func presentCaptureFailure(_ message: String) {
        if isEditorWindowVisible {
            showToast(.error(message: message))
        } else {
            presentCaptureErrorAlert(message: message)
        }
    }

    private var isEditorWindowVisible: Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue == jiminy_snippetApp.mainWindowID
                && window.isVisible
        }
    }

    private func presentCaptureErrorAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Capture Failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func confirmDiscardIfNeeded(
        messageText: String,
        informativeText: String,
        proceedButtonTitle: String
    ) -> Bool {
        guard document.hasUnsavedChanges else { return true }
        return confirmDiscardUnsavedChanges(
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
        document.applyColorToSelection(AnnotationPalette.colors[index].color)
    }

    /// Whether the rectangle style toggle should be visible — either the
    /// rectangle tool is selected (so the choice affects the next draw) or a
    /// rectangle annotation is currently selected (so the choice edits it in
    /// place).
    private var isRectangleContextActive: Bool {
        if selectedTool == .rectangle { return true }
        return document.annotations.contains {
            document.selectedAnnotationIds.contains($0.id) && $0.rectangle != nil
        }
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
        document.applyRectangleStyleToSelection(style)
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

    private var resizeControls: some View {
        Button {
            showCustomResizeSheet()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .help("Resize image")
    }

    private func showCustomResizeSheet() {
        guard let image = document.image else { return }
        // Use pixel dimensions so the dialog matches what the status bar
        // displays — and so typing "1920" produces a 1920-pixel-wide image.
        let dimensions = pixelDimensions(of: image)
        let currentWidth = dimensions.width
        let currentHeight = dimensions.height
        let aspectRatio = CGFloat(currentWidth) / CGFloat(max(currentHeight, 1))

        let model = CustomResizeModel(
            width: currentWidth,
            height: currentHeight,
            aspectRatio: aspectRatio
        )

        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Current size: \(currentWidth) × \(currentHeight) px"
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")

        let hostingView = NSHostingView(rootView: CustomResizeAccessory(model: model))
        hostingView.frame.size = hostingView.fittingSize
        alert.accessoryView = hostingView

        guard alert.runModal() == .alertFirstButtonReturn,
              model.width >= 1, model.height >= 1
        else { return }

        document.resizeImage(
            to: NSSize(width: CGFloat(model.width), height: CGFloat(model.height))
        )
        // zoomToFit() is handled by the onChange observer on document.image
    }

    private var exportMenu: some View {
        Menu {
            Button("Save") {
                save()
            }
            .help("Save the annotated image (⌘S)")
            Button("Save As...") {
                saveAs()
            }
            .help("Save the annotated image to a new file (⇧⌘S)")
            Button("Copy to Clipboard") {
                copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy the annotated image to the clipboard (⇧⌘C)")
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
        .help("Save or copy the annotated image")
    }

    /// Syncs the toolbar palette + rectangle style to the selection. Only fires
    /// for single-selection — a heterogeneous multi-selection has no obvious
    /// "current" color to surface, so we leave the toolbar alone.
    private func syncPaletteToSelection() {
        guard document.selectedAnnotationIds.count == 1,
              let id = document.selectedAnnotationIds.first,
              let annotation = document.annotations.first(where: { $0.id == id })
        else { return }
        if let rectangle = annotation.rectangle {
            // Sync the style toggle so the toolbar reflects the selection.
            rectangleFillStyle = rectangle.style
        }
        if let index = AnnotationPalette.colors.firstIndex(where: { $0.color == annotation.color }) {
            selectedColorIndex = index
        }
    }

    /// Recomputes the cached pixelated copy of the current image, which the
    /// canvas stamps clipped to the drag rect for the live pixelate preview.
    /// Built lazily — only when the pixelate tool becomes active, or when the
    /// image changes while it is — so other edits never run CIPixellate.
    private func regeneratePixelatedImage() {
        guard let image = document.image else {
            pixelatedImage = nil
            return
        }
        pixelatedImage = image.pixelated(blockSize: PixelateDefaults.blockSize(for: image.size))
    }

    private func undo() {
        guard document.undo() else { return }
        // Crop mode is view state, so the document can't exit it — but the
        // in-progress crop is meaningless against the restored image.
        if cropMode {
            cancelCrop()
        }
    }

    private func redo() {
        guard document.redo() else { return }
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
        // The pasted image has no relationship to whatever file the previous
        // screenshot was saved to — reset so ⌘S prompts for a fresh location
        // instead of silently overwriting the old file.
        document.currentFileURL = nil
        document.loadImage(image)
        // zoomToFit() is handled by the onChange observer on document.image
    }

    private func copyToClipboard() {
        guard let rendered = document.renderedImage() else { return }
        ImageExporter.copyToPasteboard(image: rendered)
        showToast(.copied)
    }

    private func save() {
        if let url = document.currentFileURL {
            writeCurrentImage(to: url)
        } else {
            saveAs()
        }
    }

    private func saveAs() {
        guard document.image != nil else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = document.currentFileURL?.lastPathComponent ?? "screenshot.png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeCurrentImage(to: url)
    }

    private func writeCurrentImage(to url: URL) {
        do {
            if try document.save(to: url) {
                showToast(.saved(url: url))
            }
        } catch {
            presentSaveError(url: url, error: error)
        }
    }

    private func showToast(_ kind: ExportToast.Kind) {
        let new = ExportToast(kind: kind)
        toastDismissTask?.cancel()
        toast = new
        let duration = kind.duration
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, toast?.id == new.id else { return }
            toast = nil
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
        guard let image = document.image else { return }
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
            document.selectedAnnotationIds.removeAll()
            selectedTool = nil
        }
    }

    private func cancelCrop() {
        cropMode = false
        cropRect = nil
    }

    private func applyCrop() {
        if let rect = cropRect {
            document.applyCrop(rect)
        }
        cropMode = false
        cropRect = nil
        // zoomToFit() is handled by the onChange observer on document.image
    }

    private func rotateImageAndAnnotations(clockwise: Bool) {
        document.rotateImage(clockwise: clockwise)
        // zoomToFit() is handled by the onChange observer on document.image
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

/// Mutable state for the custom resize dialog, shared between the SwiftUI
/// accessory view and the hosting `showCustomResizeSheet` method.
@Observable
private final class CustomResizeModel {
    var width: Int
    var height: Int
    var lockAspectRatio: Bool = true
    let aspectRatio: CGFloat

    init(width: Int, height: Int, aspectRatio: CGFloat) {
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
    }
}

/// SwiftUI accessory view for the custom resize alert.
private struct CustomResizeAccessory: View {
    @Bindable var model: CustomResizeModel

    private var widthBinding: Binding<Int> {
        Binding(
            get: { model.width },
            set: { newWidth in
                model.width = newWidth
                guard model.lockAspectRatio, newWidth > 0 else { return }
                model.height = Int(round(Double(newWidth) / model.aspectRatio))
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { model.height },
            set: { newHeight in
                model.height = newHeight
                guard model.lockAspectRatio, newHeight > 0 else { return }
                model.width = Int(round(Double(newHeight) * model.aspectRatio))
            }
        )
    }

    var body: some View {
        Form {
            TextField("Width:", value: widthBinding, format: .number)
            TextField("Height:", value: heightBinding, format: .number)
            Toggle("Lock aspect ratio", isOn: $model.lockAspectRatio)
        }
        .frame(width: 240)
    }
}

private struct ExportToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case copied
        case saved(url: URL)
        case error(message: String)
    }

    let id = UUID()
    let kind: Kind
}

extension ExportToast.Kind {
    var duration: Double {
        switch self {
        case .copied: return 2.0
        case .saved: return 2.5
        case .error: return 3.5
        }
    }
}

private struct ExportToastView: View {
    let toast: ExportToast

    @State private var hovering = false

    var body: some View {
        switch toast.kind {
        case .copied:
            label(text: "Copied to clipboard")
        case .saved(let url):
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                label(text: "Saved to \(url.lastPathComponent)", showsChevron: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointerStyle(.link)
            .help("Reveal in Finder")
        case .error(let message):
            label(text: "Capture failed: \(message)", showsErrorIcon: true)
        }
    }

    private func label(
        text: String,
        showsChevron: Bool = false,
        showsErrorIcon: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            if showsErrorIcon {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
            if showsChevron {
                Image(systemName: "arrow.up.right.square")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        }
    }
}

#Preview {
    ContentView()
        .environment(CaptureService())
        .environment(AnnotationDocument())
}
