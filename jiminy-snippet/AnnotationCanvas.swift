//
//  AnnotationCanvas.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

struct AnnotationCanvas: View {
    let image: NSImage
    /// Pre-pixelated copy of `image`, kept in sync by the parent. Used to
    /// preview the destructive pixelate tool while the user drags. Optional
    /// because the cache may be momentarily out of date right after the
    /// underlying image changes.
    let pixelatedImage: NSImage?
    @Binding var selectedTool: AnnotationTool?
    let selectedColor: Color
    let rectangleFillStyle: RectangleFillStyle
    @Binding var scale: CGFloat
    let minScale: CGFloat
    let maxScale: CGFloat
    @Binding var cropMode: Bool
    @Binding var cropRect: CGRect?
    var onCropApply: () -> Void = {}
    var onCropCancel: () -> Void = {}

    /// Annotations, selection, and undo snapshots all live here; gesture
    /// handlers mutate the document directly through the conveniences below.
    @Environment(AnnotationDocument.self) private var document

    private var annotations: [Annotation] {
        get { document.annotations }
        nonmutating set { document.annotations = newValue }
    }

    private var selectedAnnotationIds: Set<UUID> {
        get { document.selectedAnnotationIds }
        nonmutating set { document.selectedAnnotationIds = newValue }
    }

    // MARK: - Gesture State

    @State private var dragController = CanvasDragController()
    @State private var editing: EditingState?
    @FocusState private var focusedTextId: UUID?
    @State private var lastTapTime: Date?
    @State private var lastTapLocation: CGPoint?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?

    // Scroll view state used to keep the viewport centred over the same
    // image-space point when `scale` changes.
    @State private var scrollPosition = ScrollPosition()
    @State private var viewportSize: CGSize = .zero
    @State private var scrollContentOffset: CGPoint = .zero

    // Snapshot of `scale` taken at the start of a pinch-to-zoom gesture so
    // each onChanged update can be computed from a stable base rather than
    // compounding on the previous frame.
    @State private var scaleAtPinchStart: CGFloat?

    private var imageSize: CGSize { image.size }

    private var textSizes: [UUID: CGSize] {
        var sizes: [UUID: CGSize] = [:]
        for annotation in annotations {
            if let text = annotation.text {
                sizes[text.id] = AnnotationRenderer.measureText(text)
            }
        }
        return sizes
    }

    /// The single selected annotation, or nil when zero or many are selected.
    /// Resize/rotate handles only activate against this id, so multi-selection
    /// suppresses handle hit-testing alongside handle rendering.
    private var singleSelectedId: UUID? {
        selectedAnnotationIds.count == 1 ? selectedAnnotationIds.first : nil
    }

    private func hitTest(at point: CGPoint) -> AnnotationHit? {
        hitTestAnnotations(
            at: point, annotations: annotations,
            selectedId: singleSelectedId, textSizes: textSizes
        )
    }

    /// Per-event snapshot handed to the drag controller. Built fresh in each
    /// gesture callback so modifier keys and tool state are always current.
    private var dragContext: CanvasDragController.Context {
        CanvasDragController.Context(
            document: document,
            imageSize: imageSize,
            selectedTool: selectedTool,
            selectedColor: selectedColor,
            rectangleFillStyle: rectangleFillStyle,
            cropMode: cropMode,
            shiftPressed: NSEvent.modifierFlags.contains(.shift),
            textSizes: textSizes
        )
    }

    var body: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    annotationCanvas
                    gestureLayer
                    dragOutLayer

                    if let editingId = editing?.id,
                       let annotation = annotations.first(where: { $0.id == editingId })?.text {
                        editingOverlay(for: annotation, id: editingId)
                    }
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .compositingGroup()
                .scaleEffect(scale)
                .frame(
                    width: imageSize.width * scale,
                    height: imageSize.height * scale
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, new in
                scrollContentOffset = new
            }
            .onScrollGeometryChange(for: CGSize.self, of: { $0.containerSize }) { _, new in
                viewportSize = new
            }
            .simultaneousGesture(pinchZoomGesture)
            .overlay { cropInstructionOverlay }
        }
        .onChange(of: scale) { oldValue, newValue in
            recenterAfterZoom(from: oldValue, to: newValue)
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event)
            }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                handleScrollWheel(event)
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
    }

    // MARK: - Keyboard

    private enum KeyCode {
        static let backspace: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let escape: UInt16 = 53
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case KeyCode.backspace, KeyCode.forwardDelete:
            if editing == nil, !selectedAnnotationIds.isEmpty {
                document.deleteSelection()
                return nil
            }
        case KeyCode.escape:
            if cropMode {
                onCropCancel()
                return nil
            }
            if editing == nil, !selectedAnnotationIds.isEmpty {
                selectedAnnotationIds.removeAll()
                return nil
            }
        default:
            break
        }
        return event
    }

    // MARK: - Canvas

    private var annotationCanvas: some View {
        Canvas { context, _ in
            context.draw(
                Image(nsImage: image),
                in: CGRect(origin: .zero, size: imageSize)
            )

            // Resize/rotate handles only render when exactly one annotation is
            // selected; the multi-select case still shows the highlight glow
            // around each member but suppresses manipulation handles.
            let isSingleSelection = selectedAnnotationIds.count == 1

            // Array order is z-order: earlier annotations draw underneath
            // later ones, matching the reverse-order hit testing.
            for annotation in annotations {
                let selected = selectedAnnotationIds.contains(annotation.id)
                switch annotation {
                case .arrow(let arrow):
                    AnnotationRenderer.drawArrow(
                        arrow,
                        selected: selected,
                        showHandles: selected && isSingleSelection,
                        in: &context
                    )
                case .rectangle(let rectangle):
                    AnnotationRenderer.drawRectangle(
                        rectangle,
                        selected: selected,
                        showHandles: selected && isSingleSelection,
                        in: &context
                    )
                case .text(let text):
                    guard text.id != editing?.id else { break }
                    let (resolved, size) = AnnotationRenderer.resolveText(text, in: context)
                    AnnotationRenderer.drawText(text, resolved: resolved, size: size, in: &context)
                    if selected {
                        AnnotationRenderer.drawTextSelection(
                            text,
                            size: size,
                            showHandles: isSingleSelection,
                            in: &context
                        )
                    }
                }
            }

            if case .creatingArrow(let start, let end) = dragController.operation {
                AnnotationRenderer.drawCartoonArrow(
                    start: start,
                    end: end,
                    color: selectedColor,
                    lineWidth: ArrowAnnotation.defaultLineWidth,
                    selected: false,
                    in: &context
                )
            }

            if case .creatingRectangle(let start, let end) = dragController.operation {
                let draft = RectangleAnnotation(
                    rect: CGRect(from: start, to: end),
                    color: selectedColor,
                    style: rectangleFillStyle
                )
                AnnotationRenderer.drawRectangle(draft, selected: false, showHandles: false, in: &context)
            }

            if case .creatingPixelate(let start, let end) = dragController.operation {
                AnnotationRenderer.drawPixelatePreview(
                    rect: CGRect(from: start, to: end),
                    pixelatedSource: pixelatedImage,
                    canvasScale: scale,
                    in: &context
                )
            }

            if cropMode {
                drawCropOverlay(in: &context)
            }

            if case .marqueeSelecting(let start, let end, _, _) = dragController.operation {
                drawMarquee(start: start, end: end, in: &context)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(false)
    }

    /// Translucent fill plus a 1-device-pixel dashed outline. Stroke width is
    /// inverse-scaled so the marquee reads the same regardless of zoom.
    private func drawMarquee(start: CGPoint, end: CGPoint, in context: inout GraphicsContext) {
        let rect = CGRect(from: start, to: end)
        let path = Path(rect)
        context.fill(path, with: .color(.accentColor.opacity(0.12)))
        let lineWidth = 1.0 / max(scale, 0.1)
        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: lineWidth, dash: [4 * lineWidth, 3 * lineWidth])
        )
    }

    // MARK: - Crop Overlay

    /// Instructional hint shown while crop mode is active but the user hasn't
    /// yet drawn a selection. Sits in the ScrollView's viewport space (not
    /// image space), so it stays centred regardless of zoom or scroll.
    @ViewBuilder
    private var cropInstructionOverlay: some View {
        if cropMode, cropRect == nil, !isCroppingDrag {
            Text("Drag to select a crop region · Esc to cancel")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(radius: 4)
                .allowsHitTesting(false)
        }
    }

    private var isCroppingDrag: Bool {
        if case .croppingSelection = dragController.operation { return true }
        return false
    }

    private func drawCropOverlay(in context: inout GraphicsContext) {
        let imageBounds = CGRect(origin: .zero, size: imageSize)

        let overlayRect: CGRect? = {
            if case .croppingSelection(let start, let end) = dragController.operation {
                return CGRect(from: start, to: end).intersection(imageBounds)
            }
            return cropRect
        }()

        let dimColor = GraphicsContext.Shading.color(.black.opacity(0.5))

        if let rect = overlayRect, rect.width > 0, rect.height > 0 {
            var dimPath = Path()
            dimPath.addRect(imageBounds)
            dimPath.addRect(rect)
            context.fill(dimPath, with: dimColor, style: FillStyle(eoFill: true))

            context.stroke(
                Path(rect),
                with: .color(.white),
                lineWidth: 1.5 / max(scale, 0.1)
            )
        } else {
            context.fill(Path(imageBounds), with: dimColor)
        }
    }

    // MARK: - Gesture Layer

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: imageSize.width, height: imageSize.height)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        dragController.dragChanged(
                            location: value.location,
                            translation: value.translation,
                            startLocation: value.startLocation,
                            context: dragContext
                        )
                    }
                    .onEnded { value in
                        applyDragEnd(
                            dragController.dragEnded(location: value.location, context: dragContext)
                        )
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(at: value.location)
                    }
            )
            .allowsHitTesting(editing == nil)
    }

    // MARK: - Drag-Out Layer

    /// Sits above the gesture layer and only claims clicks that land on
    /// empty image background while no tool/crop/edit is active. Hands those
    /// clicks to AppKit so the canvas image can be dragged out into Finder,
    /// Slack, Mail, etc.
    private var dragOutLayer: some View {
        DragOutHandle(
            makeSource: { dragOutSource() },
            isEmptySpace: { canStartDragOut(at: $0) },
            onClickWithoutDrag: {
                // Shift-click on empty space leaves multi-selection intact —
                // matches the shift-toggle convention used inside hit areas.
                if !NSEvent.modifierFlags.contains(.shift) {
                    selectedAnnotationIds.removeAll()
                }
            }
        )
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(editing == nil)
    }

    private func dragOutSource() -> DragOutSource? {
        // Fall back to "screenshot.png" when unsaved so the canvas produces a
        // sensible file promise even before the user has saved.
        DragOutSource(
            image: image,
            annotations: annotations,
            suggestedFilename: document.currentFileURL?.lastPathComponent ?? "screenshot.png"
        )
    }

    /// True when starting a drag at `point` should trigger a system drag-out
    /// rather than any annotation interaction. Mirrors the conditions in
    /// `beginDrag` so we never steal clicks from drawing, selection, or panning.
    /// Requires the Option key — plain empty-space drags fall through to the
    /// gesture layer so marquee selection can claim them.
    private func canStartDragOut(at point: CGPoint) -> Bool {
        if cropMode { return false }
        if selectedTool != nil { return false }
        if editing != nil { return false }
        if hitTest(at: point) != nil { return false }
        if !NSEvent.modifierFlags.contains(.option) { return false }
        return true
    }

    // MARK: - Editing Overlay

    /// Tap-catcher (commits on outside tap) plus the in-place TextField, layered as one.
    private func editingOverlay(for annotation: TextAnnotation, id: UUID) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { commitTextEditing(id: id) }
            textFieldOverlay(for: annotation)
        }
        .frame(width: imageSize.width, height: imageSize.height)
    }

    private func textFieldOverlay(for annotation: TextAnnotation) -> some View {
        let annotationId = annotation.id
        let textBinding = Binding<String>(
            get: { annotations.first(where: { $0.id == annotationId })?.text?.text ?? "" },
            set: { newValue in
                annotations.updateText(id: annotationId) { $0.text = newValue }
            }
        )
        return TextField("", text: textBinding)
            .font(.system(size: annotation.fontSize, weight: .bold))
            .foregroundStyle(annotation.color)
            .textFieldStyle(.plain)
            .fixedSize()
            .padding(.horizontal, RenderConstants.textPaddingH)
            .padding(.vertical, RenderConstants.textPaddingV)
            .focused($focusedTextId, equals: annotationId)
            // Force a non-identity transform on the TextField's layer. Without
            // this, SwiftUI collapses `scaleEffect(1.0)` to identity, which
            // leaves macOS's shared field editor unable to paint the insertion
            // caret on the second and subsequent edit sessions at 100% zoom.
            .scaleEffect(1.0001, anchor: .topLeading)
            .scaleEffect(x: annotation.scaleX, y: annotation.scaleY, anchor: .topLeading)
            .rotationEffect(.degrees(annotation.rotation), anchor: .topLeading)
            .offset(x: annotation.position.x, y: annotation.position.y)
            .onAppear { focusedTextId = annotationId }
            .onSubmit {
                commitTextEditing(id: annotationId)
            }
            .onExitCommand {
                cancelTextEditing(id: annotationId)
            }
    }

    // MARK: - Drag Handling

    /// Applies the view-state consequences of a finished drag — the document
    /// mutations already happened inside the drag controller.
    private func applyDragEnd(_ effect: CanvasDragController.EndEffect) {
        switch effect {
        case .none:
            break
        case .toolFinished:
            selectedTool = nil
        case .cropSelected(let rect):
            cropRect = rect
            if rect != nil {
                onCropApply()
            }
        }
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint) {
        if cropMode { return }

        // Double-tap detection
        let now = Date()
        if let lastTime = lastTapTime,
           let lastLoc = lastTapLocation,
           now.timeIntervalSince(lastTime) < NSEvent.doubleClickInterval,
           hypot(location.x - lastLoc.x, location.y - lastLoc.y) < 10 {
            lastTapTime = nil
            lastTapLocation = nil
            handleDoubleTap(at: location)
            return
        }
        lastTapTime = now
        lastTapLocation = location

        if selectedTool == .text {
            createTextAnnotation(at: location)
            return
        }

        let isShift = NSEvent.modifierFlags.contains(.shift)
        if let hit = hitTest(at: location) {
            let id = hit.id
            if isShift {
                // Toggle: shift-clicking an already-selected annotation removes
                // it from the selection without disturbing the others.
                if selectedAnnotationIds.contains(id) {
                    selectedAnnotationIds.remove(id)
                } else {
                    selectedAnnotationIds.insert(id)
                }
            } else {
                selectedAnnotationIds = [id]
            }
        } else if !isShift {
            selectedAnnotationIds.removeAll()
        }
    }

    private func handleDoubleTap(at location: CGPoint) {
        if case .text(let id, _) = hitTest(at: location) {
            startEditing(id: id)
        }
    }

    // MARK: - Text Editing

    private func createTextAnnotation(at location: CGPoint) {
        if let editingId = editing?.id {
            commitTextEditing(id: editingId)
        }

        document.recordSnapshot()
        let annotation = TextAnnotation(
            position: location,
            text: "",
            color: selectedColor
        )
        annotations.append(.text(annotation))
        editing = EditingState(id: annotation.id, originalText: "")
        focusedTextId = annotation.id
        selectedAnnotationIds = [annotation.id]
        selectedTool = nil
    }

    private func startEditing(id: UUID) {
        guard let annotation = annotations.first(where: { $0.id == id })?.text else { return }
        document.recordSnapshot()
        editing = EditingState(id: id, originalText: annotation.text)
        selectedAnnotationIds = [id]
    }

    private func commitTextEditing(id: UUID) {
        if let index = annotations.firstIndex(where: { $0.id == id }),
           annotations[index].text?.text.isEmpty == true {
            annotations.remove(at: index)
        }
        editing = nil
        focusedTextId = nil
    }

    private func cancelTextEditing(id: UUID) {
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            if let original = editing?.originalText, !original.isEmpty {
                annotations.updateText(id: id) { $0.text = original }
            } else {
                annotations.remove(at: index)
            }
        }
        // The snapshot pushed at the start of editing now represents a no-op,
        // since the cancel reverted to the pre-edit state. Drop it so the user
        // doesn't burn an undo slot stepping over cancelled edits.
        document.discardLastSnapshot()
        editing = nil
        focusedTextId = nil
    }

    /// ⌘+scroll zoom, matching the convention in Preview/Safari/Xcode. On a
    /// trackpad this is the familiar "hold ⌘ and two-finger drag" gesture.
    /// Returning `nil` swallows the event so the underlying `ScrollView`
    /// doesn't also pan while the user is zooming. Events without the Command
    /// modifier — or events that land outside this window — are passed
    /// through untouched.
    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command),
              event.window === NSApp.keyWindow
        else { return event }

        // `scrollingDeltaY` is in points for pixel-precise devices and in
        // line-counts for classic wheels. The 0.01 factor gives pinch-like
        // feel on a trackpad without being glacial on a mouse wheel.
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return nil }

        let factor = 1 + delta * 0.01
        let target = scale * factor
        scale = min(maxScale, max(minScale, target))
        return nil
    }

    /// Trackpad pinch-to-zoom. Runs simultaneously with the drag/tap gestures
    /// on the canvas so annotation editing is unaffected. Each `onChanged`
    /// event is computed from the scale captured at gesture start, so the
    /// cumulative magnification maps directly onto the user's pinch.
    private var pinchZoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if scaleAtPinchStart == nil {
                    scaleAtPinchStart = scale
                }
                let base = scaleAtPinchStart ?? scale
                let target = base * value.magnification
                scale = min(maxScale, max(minScale, target))
            }
            .onEnded { _ in
                scaleAtPinchStart = nil
            }
    }

    /// Keeps the point currently at the viewport centre pinned there across a
    /// change in `scale`. Without this, the `ScrollView` preserves its raw
    /// pixel offset, so zooming appears to pivot around an arbitrary location.
    private func recenterAfterZoom(from oldScale: CGFloat, to newScale: CGFloat) {
        guard oldScale != newScale,
              oldScale > 0,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }

        // Image-space point that was centred in the viewport before the zoom.
        let focus = CGPoint(
            x: (scrollContentOffset.x + viewportSize.width / 2) / oldScale,
            y: (scrollContentOffset.y + viewportSize.height / 2) / oldScale
        )

        // Top-left offset required to put that same point back in the centre.
        let newOffset = CGPoint(
            x: focus.x * newScale - viewportSize.width / 2,
            y: focus.y * newScale - viewportSize.height / 2
        )
        scrollPosition.scrollTo(point: newOffset)
    }
}

// MARK: - Supporting Types

private struct EditingState {
    let id: UUID
    let originalText: String
}
