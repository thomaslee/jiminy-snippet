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
    @State private var selectedAnnotationIds: Set<UUID> = []
    @State private var cropMode: Bool = false
    @State private var cropRect: CGRect? = nil
    @State private var undoHistory = UndoHistory()
    /// Pre-pixelated copy of the current image, regenerated when the
    /// underlying image changes (new capture, crop, rotate, resize, pixelate
    /// commit). Used as the live preview while the user drags the destructive
    /// pixelate tool.
    @State private var pixelatedImage: NSImage?
    @State private var toast: ExportToast?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var isHandlingIncomingCapture = false

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
            .onChange(of: screenshotManager.capturedImage) { oldImage, newImage in
                markUnsaved()
                // Re-fit only when the image dimensions actually change
                // (crop/resize/rotate/new-capture). A same-size swap — e.g.
                // committing a pixelate — keeps the user's current zoom.
                if oldImage?.size != newImage?.size {
                    zoomToFit()
                }
                regeneratePixelatedImage()
            }
            .onChange(of: screenshotManager.incomingCapture) {
                handleIncomingCapture()
            }
            .onChange(of: selectedAnnotationIds) {
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
            .onChange(of: screenshotManager.captureError) {
                handleCaptureError()
            }
            .modifier(SceneCommandValues(
                hasImage: screenshotManager.capturedImage != nil,
                canZoomIn: scale < maxScale,
                canZoomOut: scale > minScale,
                canUndo: undoHistory.canUndo,
                canRedo: undoHistory.canRedo,
                canDuplicate: !selectedAnnotationIds.isEmpty,
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
                    pixelatedImage: pixelatedImage,
                    arrows: $arrows,
                    texts: $texts,
                    rectangles: $rectangles,
                    selectedTool: $selectedTool,
                    selectedAnnotationIds: $selectedAnnotationIds,
                    selectedColor: selectedColor,
                    rectangleFillStyle: rectangleFillStyle,
                    scale: $scale,
                    minScale: minScale,
                    maxScale: maxScale,
                    cropMode: $cropMode,
                    cropRect: $cropRect,
                    dragOutFilename: screenshotManager.currentFileURL?.lastPathComponent,
                    onCropApply: applyCrop,
                    onCropCancel: cancelCrop,
                    onBeginEdit: recordSnapshot,
                    onDiscardEdit: discardLastSnapshot,
                    onApplyPixelate: applyPixelation
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
            if screenshotManager.capturedImage != nil {
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
                beginNewCapture { screenshotManager.captureFullscreen() }
            }
            .help("Capture the entire screen")
            Button("Screen region...") {
                beginNewCapture { screenshotManager.captureRegion() }
            }
            .help("Drag to capture a rectangular region of the screen")
            Menu("Screen region with delay...") {
                ForEach(timedCaptureDurations, id: \.self) { seconds in
                    Button("\(seconds) Seconds") {
                        beginNewCapture {
                            screenshotManager.captureRegionAfterDelay(seconds: seconds)
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

    /// Starts a new capture flow. The unsaved-changes prompt is deferred
    /// until the capture actually succeeds (see `handleIncomingCapture`) so
    /// cancelling region selection or the countdown doesn't throw away edits.
    private func beginNewCapture(_ capture: () -> Void) {
        // Abort any pending timed capture so switching capture modes mid-
        // countdown restores the Jiminy window before the new action runs.
        screenshotManager.cancelTimedCapture()
        capture()
    }

    /// Adopts a freshly-acquired capture, prompting the user to discard
    /// unsaved edits first if necessary. If the user declines, the new image
    /// is dropped and existing edits are preserved.
    ///
    /// The `isHandlingIncomingCapture` flag guards against re-entrancy:
    /// `NSAlert.runModal()` pumps the event loop, so a second capture landing
    /// mid-prompt would otherwise recursively invoke this method. Today no
    /// code path can deliver a second capture while the modal is up, so the
    /// guard is belt-and-braces. When we add a global hotkey for region
    /// capture (or any other background-triggered capture path) it becomes
    /// load-bearing, and at that point it's worth replacing this whole
    /// `runModal` flow with a SwiftUI `.confirmationDialog` driven by an
    /// optional pending-capture state — non-blocking, no nested event loop,
    /// and serialization falls out of the dialog's own state machine.
    private func handleIncomingCapture() {
        guard !isHandlingIncomingCapture else { return }
        guard let image = screenshotManager.incomingCapture else { return }
        screenshotManager.incomingCapture = nil
        isHandlingIncomingCapture = true
        defer { isHandlingIncomingCapture = false }
        guard confirmDiscardIfNeeded(
            messageText: "You have unsaved changes",
            informativeText: "Taking a new screenshot will discard your current edits. Continue?",
            proceedButtonTitle: "Continue"
        ) else { return }
        clearAnnotations()
        screenshotManager.currentFileURL = nil
        screenshotManager.capturedImage = image
    }

    /// Surfaces the most recent capture failure as a toast when the editor
    /// window is on screen, or as an `NSAlert` when it isn't (e.g. a menu-bar
    /// triggered capture that failed before the window finished opening).
    /// Clears the published error so subsequent identical failures retoast.
    private func handleCaptureError() {
        guard let message = screenshotManager.captureError else { return }
        screenshotManager.captureError = nil
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
        guard !selectedAnnotationIds.isEmpty else { return }

        let ids = selectedAnnotationIds
        let needsChange = arrows.contains(where: { ids.contains($0.id) && $0.color != color })
            || texts.contains(where: { ids.contains($0.id) && $0.color != color })
            || rectangles.contains(where: { ids.contains($0.id) && $0.color != color })
        guard needsChange else { return }

        recordSnapshot()
        for i in arrows.indices where ids.contains(arrows[i].id) {
            arrows[i].color = color
        }
        for i in texts.indices where ids.contains(texts[i].id) {
            texts[i].color = color
        }
        for i in rectangles.indices where ids.contains(rectangles[i].id) {
            rectangles[i].color = color
        }
    }

    /// Whether the rectangle style toggle should be visible — either the
    /// rectangle tool is selected (so the choice affects the next draw) or a
    /// rectangle annotation is currently selected (so the choice edits it in
    /// place).
    private var isRectangleContextActive: Bool {
        if selectedTool == .rectangle { return true }
        return rectangles.contains(where: { selectedAnnotationIds.contains($0.id) })
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
        let ids = selectedAnnotationIds
        let needsChange = rectangles.contains(where: { ids.contains($0.id) && $0.style != style })
        guard needsChange else { return }
        recordSnapshot()
        for i in rectangles.indices where ids.contains(rectangles[i].id) {
            rectangles[i].style = style
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

    private var resizeControls: some View {
        Button {
            showCustomResizeSheet()
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .help("Resize image")
    }

    private func applyResize(to newSize: NSSize) {
        guard let image = screenshotManager.capturedImage,
              let resized = image.resized(to: newSize)
        else { return }

        let oldSize = image.size
        guard oldSize.width > 0, oldSize.height > 0 else { return }

        recordSnapshot()

        let sx = newSize.width / oldSize.width
        let sy = newSize.height / oldSize.height

        for i in arrows.indices {
            arrows[i].start.x *= sx
            arrows[i].start.y *= sy
            arrows[i].end.x *= sx
            arrows[i].end.y *= sy
            arrows[i].lineWidth *= min(sx, sy)
        }
        for i in texts.indices {
            texts[i].position.x *= sx
            texts[i].position.y *= sy
            texts[i].fontSize *= min(sx, sy)
        }
        for i in rectangles.indices {
            let r = rectangles[i].rect
            rectangles[i].rect = CGRect(
                x: r.origin.x * sx,
                y: r.origin.y * sy,
                width: r.width * sx,
                height: r.height * sy
            )
            rectangles[i].lineWidth *= min(sx, sy)
        }

        selectedAnnotationIds.removeAll()
        screenshotManager.capturedImage = resized
        // markUnsaved() and zoomToFit() are handled by onChange observers
    }

    private func showCustomResizeSheet() {
        guard let image = screenshotManager.capturedImage else { return }
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

        applyResize(to: NSSize(width: CGFloat(model.width), height: CGFloat(model.height)))
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
        guard selectedAnnotationIds.count == 1,
              let id = selectedAnnotationIds.first
        else { return }
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

    /// Recomputes the cached pixelated copy of the current image. Cheap when
    /// no image is loaded; otherwise runs CIPixellate once on the source.
    /// Called whenever `capturedImage` changes — fresh capture, crop, rotate,
    /// resize, paste, undo/redo that swaps the image, or a pixelate apply.
    private func regeneratePixelatedImage() {
        guard let image = screenshotManager.capturedImage else {
            pixelatedImage = nil
            return
        }
        pixelatedImage = image.pixelated(blockSize: PixelateDefaults.blockSize)
    }

    /// Applies a destructive pixelation to the captured image, replacing the
    /// rect's pixels with their pixelated equivalents. The canvas's
    /// `onBeginEdit` already pushed an undo snapshot at drag start, so the
    /// only state to mutate here is the image itself — the cached pixelated
    /// copy gets regenerated by the `capturedImage` onChange observer.
    private func applyPixelation(rect: CGRect) {
        guard let image = screenshotManager.capturedImage,
              let updated = image.pixelating(rect: rect, blockSize: PixelateDefaults.blockSize)
        else {
            return
        }
        screenshotManager.capturedImage = updated
        // Pixelating doesn't touch annotations, but it does change what's
        // beneath them — drop selection so the user reacts to the new image
        // rather than carrying selection state from the pre-redaction view.
        selectedAnnotationIds.removeAll()
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

    /// Duplicates every selected annotation, offsetting each copy so the user
    /// can see it landed on top of the original. Selection moves to the new
    /// copies so repeated invocations stack diagonally.
    private func duplicateSelectedAnnotation() {
        guard !selectedAnnotationIds.isEmpty else { return }
        let ids = selectedAnnotationIds
        let offset = CGSize(width: 20, height: 20)

        let arrowsToDup = arrows.filter { ids.contains($0.id) }
        let textsToDup = texts.filter { ids.contains($0.id) }
        let rectanglesToDup = rectangles.filter { ids.contains($0.id) }
        guard !arrowsToDup.isEmpty || !textsToDup.isEmpty || !rectanglesToDup.isEmpty else {
            return
        }

        recordSnapshot()

        var newSelection: Set<UUID> = []
        for arrow in arrowsToDup {
            let copy = arrow.duplicated(offset: offset)
            arrows.append(copy)
            newSelection.insert(copy.id)
        }
        for text in textsToDup {
            let copy = text.duplicated(offset: offset)
            texts.append(copy)
            newSelection.insert(copy.id)
        }
        for rectangle in rectanglesToDup {
            let copy = rectangle.duplicated(offset: offset)
            rectangles.append(copy)
            newSelection.insert(copy.id)
        }
        selectedAnnotationIds = newSelection
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
        selectedAnnotationIds.removeAll()
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
        showToast(.copied)
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
            showToast(.saved(url: url))
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
            selectedAnnotationIds.removeAll()
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

        selectedAnnotationIds.removeAll()
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
        selectedAnnotationIds.removeAll()
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
        .environment(ScreenshotManager())
}
