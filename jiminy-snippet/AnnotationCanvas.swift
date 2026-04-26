//
//  AnnotationCanvas.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

struct AnnotationCanvas: View {
    let image: NSImage
    @Binding var arrows: [ArrowAnnotation]
    @Binding var texts: [TextAnnotation]
    @Binding var rectangles: [RectangleAnnotation]
    @Binding var selectedTool: AnnotationTool?
    @Binding var selectedAnnotationId: UUID?
    let selectedColor: Color
    let rectangleFillStyle: RectangleFillStyle
    @Binding var scale: CGFloat
    let minScale: CGFloat
    let maxScale: CGFloat
    @Binding var cropMode: Bool
    @Binding var cropRect: CGRect?
    /// Suggested filename for drag-out exports. Falls back to "screenshot.png"
    /// when nil so the canvas can produce a sensible promise even before the
    /// user has saved.
    var dragOutFilename: String?
    var onCropApply: () -> Void = {}
    var onCropCancel: () -> Void = {}
    /// Called immediately before any discrete edit that mutates `arrows`,
    /// `texts`, or the image itself — the owner records an undo snapshot here.
    var onBeginEdit: () -> Void = {}
    /// Called when an in-flight edit is abandoned (e.g. text editing cancelled)
    /// so the matching `onBeginEdit` snapshot can be discarded.
    var onDiscardEdit: () -> Void = {}

    // MARK: - Gesture State

    @State private var dragOperation: DragOperation = .none
    @State private var editing: EditingState?
    @FocusState private var focusedTextId: UUID?
    @State private var lastTapTime: Date?
    @State private var lastTapLocation: CGPoint?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    @State private var handleMode: HandleMode = .resize

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
        for annotation in texts {
            sizes[annotation.id] = AnnotationRenderer.measureText(annotation)
        }
        return sizes
    }

    private func hitTest(at point: CGPoint) -> AnnotationHit? {
        hitTestAnnotations(
            at: point, arrows: arrows, texts: texts, rectangles: rectangles,
            selectedId: selectedAnnotationId, textSizes: textSizes
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
                       let annotation = texts.first(where: { $0.id == editingId }) {
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
        .onChange(of: selectedAnnotationId) {
            handleMode = .resize
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
            if editing == nil, let id = selectedAnnotationId {
                deleteAnnotation(id: id)
                return nil
            }
        case KeyCode.escape:
            if cropMode {
                onCropCancel()
                return nil
            }
            if editing == nil, selectedAnnotationId != nil {
                selectedAnnotationId = nil
                return nil
            }
        default:
            break
        }
        return event
    }

    private func deleteAnnotation(id: UUID) {
        guard arrows.contains(where: { $0.id == id })
                || texts.contains(where: { $0.id == id })
                || rectangles.contains(where: { $0.id == id })
        else {
            return
        }
        onBeginEdit()
        arrows.removeAll { $0.id == id }
        texts.removeAll { $0.id == id }
        rectangles.removeAll { $0.id == id }
        selectedAnnotationId = nil
    }

    // MARK: - Canvas

    private var annotationCanvas: some View {
        Canvas { context, _ in
            context.draw(
                Image(nsImage: image),
                in: CGRect(origin: .zero, size: imageSize)
            )

            for arrow in arrows {
                let selected = selectedAnnotationId == arrow.id
                AnnotationRenderer.drawArrow(arrow, selected: selected, in: &context)
            }

            for rectangle in rectangles {
                let selected = selectedAnnotationId == rectangle.id
                AnnotationRenderer.drawRectangle(rectangle, selected: selected, in: &context)
            }

            for annotation in texts where annotation.id != editing?.id {
                let (resolved, size) = AnnotationRenderer.resolveText(annotation, in: context)
                AnnotationRenderer.drawText(annotation, resolved: resolved, size: size, in: &context)
                if selectedAnnotationId == annotation.id {
                    AnnotationRenderer.drawTextSelection(
                        annotation, size: size, handleMode: handleMode, in: &context
                    )
                }
            }

            if case .creatingArrow(let start, let end) = dragOperation {
                AnnotationRenderer.drawCartoonArrow(
                    start: start,
                    end: end,
                    color: selectedColor,
                    lineWidth: ArrowAnnotation.defaultLineWidth,
                    selected: false,
                    in: &context
                )
            }

            if case .creatingRectangle(let start, let end) = dragOperation {
                let draft = RectangleAnnotation(
                    rect: CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    ),
                    color: selectedColor,
                    style: rectangleFillStyle
                )
                AnnotationRenderer.drawRectangle(draft, selected: false, in: &context)
            }

            if cropMode {
                drawCropOverlay(in: &context)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(false)
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
        if case .croppingSelection = dragOperation { return true }
        return false
    }

    private func drawCropOverlay(in context: inout GraphicsContext) {
        let imageBounds = CGRect(origin: .zero, size: imageSize)

        let overlayRect: CGRect? = {
            if case .croppingSelection(let start, let end) = dragOperation {
                return CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                ).intersection(imageBounds)
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
                        handleDragChanged(value)
                    }
                    .onEnded { value in
                        handleDragEnded(value)
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
            onClickWithoutDrag: { selectedAnnotationId = nil }
        )
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(editing == nil)
    }

    private func dragOutSource() -> DragOutSource? {
        DragOutSource(
            image: image,
            arrows: arrows,
            texts: texts,
            rectangles: rectangles,
            suggestedFilename: dragOutFilename ?? "screenshot.png"
        )
    }

    /// True when starting a drag at `point` should trigger a system drag-out
    /// rather than any annotation interaction. Mirrors the conditions in
    /// `beginDrag` so we never steal clicks from drawing, selection, or panning.
    private func canStartDragOut(at point: CGPoint) -> Bool {
        if cropMode { return false }
        if selectedTool != nil { return false }
        if editing != nil { return false }
        if hitTest(at: point) != nil { return false }
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
            get: { texts.first(where: { $0.id == annotationId })?.text ?? "" },
            set: { newValue in
                texts.update(id: annotationId) { $0.text = newValue }
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

    private func handleDragChanged(_ value: DragGesture.Value) {
        let point = value.location
        let translation = value.translation

        switch dragOperation {
        case .none:
            guard let op = beginDrag(at: value.startLocation) else { return }
            // Crop selection drags only touch `cropRect`, which isn't part of
            // the undoable canvas state — the actual crop is recorded later,
            // in ContentView.applyCrop.
            if case .croppingSelection = op {} else {
                onBeginEdit()
            }
            dragOperation = op
            // Re-enter so the current translation is applied immediately,
            // rather than waiting one frame for the next drag event.
            handleDragChanged(value)

        case .creatingArrow(let start, _):
            dragOperation = .creatingArrow(start: start, end: point)

        case .creatingRectangle(let start, _):
            dragOperation = .creatingRectangle(start: start, end: point)

        case .croppingSelection(let start, _):
            dragOperation = .croppingSelection(start: start, end: point)

        case .movingArrow(let id, let initialStart, let initialEnd, let mask):
            arrows.update(id: id) { arrow in
                if mask.contains(.start) { arrow.start = initialStart + translation }
                if mask.contains(.end)   { arrow.end   = initialEnd + translation }
            }

        case .movingRectangle(let id, let initial):
            rectangles.update(id: id) {
                $0.rect = initial.offsetBy(dx: translation.width, dy: translation.height)
            }

        case .resizingRectangle(let id, let initial, let handle):
            rectangles.update(id: id) {
                $0.rect = resizedRect(initial: initial, handle: handle, translation: translation)
            }

        case .movingText(let id, let initial):
            texts.update(id: id) { $0.position = initial + translation }

        case .scalingText(let id, let axis, let initialScaleX, let initialScaleY,
                         let center, let paddedWidth, let paddedHeight, let initialRef):
            guard initialRef > 0.001 else { break }
            texts.update(id: id) { text in
                let rad = text.rotation * .pi / 180
                var newSX = initialScaleX
                var newSY = initialScaleY

                switch axis {
                case .uniform:
                    let dist = hypot(point.x - center.x, point.y - center.y)
                    let factor = dist / initialRef
                    newSX = initialScaleX * factor
                    newSY = initialScaleY * factor

                case .horizontal:
                    let axisX = cos(rad), axisY = sin(rad)
                    let proj = (point.x - center.x) * axisX + (point.y - center.y) * axisY
                    newSX = initialScaleX * abs(proj) / initialRef

                case .vertical:
                    let axisX = -sin(rad), axisY = cos(rad)
                    let proj = (point.x - center.x) * axisX + (point.y - center.y) * axisY
                    newSY = initialScaleY * abs(proj) / initialRef
                }

                newSX = max(0.2, newSX)
                newSY = max(0.2, newSY)
                text.scaleX = newSX
                text.scaleY = newSY

                // Reposition so center stays fixed
                let newLocalCenter = CGPoint(
                    x: paddedWidth * newSX / 2,
                    y: paddedHeight * newSY / 2
                )
                text.position = CGPoint(
                    x: center.x - (newLocalCenter.x * cos(rad) - newLocalCenter.y * sin(rad)),
                    y: center.y - (newLocalCenter.x * sin(rad) + newLocalCenter.y * cos(rad))
                )
            }

        case .rotatingText(let id, let initialRotation, let referenceAngle, let center):
            texts.update(id: id) { text in
                let currentAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
                text.rotation = initialRotation + (currentAngle - referenceAngle)
            }
        }
    }

    /// Decides what kind of drag the user is starting at `startPoint`.
    /// Mutates selection state as a side-effect, but only returns a `DragOperation`
    /// when an actual drag should begin.
    private func beginDrag(at startPoint: CGPoint) -> DragOperation? {
        if cropMode {
            return .croppingSelection(start: startPoint, end: startPoint)
        }

        if selectedTool == .arrow {
            selectedAnnotationId = nil
            return .creatingArrow(start: startPoint, end: startPoint)
        }

        if selectedTool == .rectangle {
            selectedAnnotationId = nil
            return .creatingRectangle(start: startPoint, end: startPoint)
        }

        guard let hit = hitTest(at: startPoint) else { return nil }

        switch hit {
        case .arrow(let id, let zone):
            selectedAnnotationId = id
            guard let arrow = arrows.first(where: { $0.id == id }) else { return nil }
            let mask: ArrowEndpointMask
            switch zone {
            case .startEndpoint: mask = .start
            case .endEndpoint:   mask = .end
            case .body:          mask = .both
            default:             return nil
            }
            return .movingArrow(
                id: id, initialStart: arrow.start, initialEnd: arrow.end, mask: mask
            )

        case .text(let id, let zone):
            selectedAnnotationId = id
            guard let annotation = texts.first(where: { $0.id == id }) else { return nil }
            switch zone {
            case .handle(let handlePos):
                return handleMode == .rotate
                    ? beginRotation(for: annotation, from: startPoint)
                    : beginTextScaling(for: annotation, handle: handlePos)
            case .body:
                return .movingText(id: id, initialPosition: annotation.position)
            case .exterior:
                return handleMode == .rotate
                    ? beginRotation(for: annotation, from: startPoint)
                    : nil
            default:
                return nil
            }

        case .rectangle(let id, let zone):
            selectedAnnotationId = id
            guard let rectangle = rectangles.first(where: { $0.id == id }) else { return nil }
            switch zone {
            case .body:
                return .movingRectangle(id: id, initialRect: rectangle.rect)
            case .handle(let handlePos):
                return .resizingRectangle(
                    id: id,
                    initialRect: rectangle.rect.standardized,
                    handle: handlePos
                )
            default:
                return nil
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        if case .creatingArrow(let start, _) = dragOperation {
            let end = value.location
            let arrow = ArrowAnnotation(start: start, end: end, color: selectedColor)
            arrows.append(arrow)
            selectedAnnotationId = arrow.id
            selectedTool = nil
        } else if case .creatingRectangle(let start, _) = dragOperation {
            let end = value.location
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if rect.width > 1, rect.height > 1 {
                let rectangle = RectangleAnnotation(
                    rect: rect,
                    color: selectedColor,
                    style: rectangleFillStyle
                )
                rectangles.append(rectangle)
                selectedAnnotationId = rectangle.id
            }
            selectedTool = nil
        } else if case .resizingRectangle(let id, _, _) = dragOperation {
            // Normalize at the end of a resize so flipped rects are stored
            // with positive width/height. Hit testing already standardizes,
            // but keeping the stored value tidy avoids surprises elsewhere.
            rectangles.update(id: id) { $0.rect = $0.rect.standardized }
        } else if case .croppingSelection(let start, _) = dragOperation {
            let end = value.location
            let imageBounds = CGRect(origin: .zero, size: imageSize)
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ).intersection(imageBounds)
            if rect.width > 1 && rect.height > 1 {
                cropRect = rect
                onCropApply()
            } else {
                cropRect = nil
            }
        }
        dragOperation = .none
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

        if let hit = hitTest(at: location) {
            switch hit {
            case .arrow(let id, _): selectedAnnotationId = id
            case .rectangle(let id, _): selectedAnnotationId = id
            case .text(let id, _):
                if id == selectedAnnotationId {
                    handleMode = handleMode == .resize ? .rotate : .resize
                } else {
                    selectedAnnotationId = id
                }
            }
        } else {
            selectedAnnotationId = nil
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

        onBeginEdit()
        let annotation = TextAnnotation(
            position: location,
            text: "",
            color: selectedColor
        )
        texts.append(annotation)
        editing = EditingState(id: annotation.id, originalText: "")
        focusedTextId = annotation.id
        selectedAnnotationId = annotation.id
        selectedTool = nil
    }

    private func startEditing(id: UUID) {
        guard let annotation = texts.first(where: { $0.id == id }) else { return }
        onBeginEdit()
        editing = EditingState(id: id, originalText: annotation.text)
        selectedAnnotationId = id
    }

    private func commitTextEditing(id: UUID) {
        if let index = texts.firstIndex(where: { $0.id == id }) {
            if texts[index].text.isEmpty {
                texts.remove(at: index)
            }
        }
        editing = nil
        focusedTextId = nil
    }

    private func cancelTextEditing(id: UUID) {
        if let index = texts.firstIndex(where: { $0.id == id }) {
            if let original = editing?.originalText, !original.isEmpty {
                texts[index].text = original
            } else {
                texts.remove(at: index)
            }
        }
        // The snapshot pushed at the start of editing now represents a no-op,
        // since the cancel reverted to the pre-edit state. Drop it so the user
        // doesn't burn an undo slot stepping over cancelled edits.
        onDiscardEdit()
        editing = nil
        focusedTextId = nil
    }

    /// Builds a `rotatingText` drag operation anchored at the annotation's center.
    private func beginRotation(
        for annotation: TextAnnotation,
        from startPoint: CGPoint
    ) -> DragOperation {
        let center = textCenter(for: annotation)
        let referenceAngle = atan2(
            startPoint.y - center.y,
            startPoint.x - center.x
        ) * 180 / .pi
        return .rotatingText(
            id: annotation.id,
            initialRotation: annotation.rotation,
            referenceAngle: referenceAngle,
            center: center
        )
    }

    /// Builds a `scalingText` drag operation for the given handle.
    /// Decides scaling axis (uniform/horizontal/vertical) and the reference distance
    /// against which subsequent drag distances are normalised.
    private func beginTextScaling(
        for annotation: TextAnnotation,
        handle handlePos: HandlePosition
    ) -> DragOperation {
        let measured = AnnotationRenderer.measureText(annotation)
        let padded = RenderConstants.paddedTextSize(measured)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )
        let center = textCenter(for: annotation)

        let axis: ScaleAxis
        let initialRef: CGFloat
        if handlePos.isCorner {
            axis = .uniform
            let handleLocal = handlePos.localPoint(scaledSize: scaledSize)
            let handleCanvas = AnnotationRenderer.localToCanvas(
                handleLocal, origin: annotation.position, angle: annotation.rotation
            )
            initialRef = hypot(handleCanvas.x - center.x, handleCanvas.y - center.y)
        } else if handlePos == .left || handlePos == .right {
            axis = .horizontal
            initialRef = padded.width * annotation.scaleX / 2
        } else {
            axis = .vertical
            initialRef = padded.height * annotation.scaleY / 2
        }

        return .scalingText(
            id: annotation.id,
            axis: axis,
            initialScaleX: annotation.scaleX,
            initialScaleY: annotation.scaleY,
            center: center,
            paddedWidth: padded.width,
            paddedHeight: padded.height,
            initialRef: initialRef
        )
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

    /// Computes the new rect produced by dragging a rectangle handle by
    /// `translation`. The returned rect may be non-standardized (negative
    /// width/height) while the user drags past the opposite edge — callers
    /// standardize at the end of the drag.
    private func resizedRect(
        initial: CGRect,
        handle: HandlePosition,
        translation: CGSize
    ) -> CGRect {
        var minX = initial.minX
        var minY = initial.minY
        var maxX = initial.maxX
        var maxY = initial.maxY

        let dx = translation.width
        let dy = translation.height

        switch handle {
        case .topLeft:     minX += dx; minY += dy
        case .top:                     minY += dy
        case .topRight:    maxX += dx; minY += dy
        case .left:        minX += dx
        case .right:       maxX += dx
        case .bottomLeft:  minX += dx; maxY += dy
        case .bottom:                  maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Returns the center of a text annotation's scaled bounding box in canvas space.
    private func textCenter(for annotation: TextAnnotation) -> CGPoint {
        let padded = RenderConstants.paddedTextSize(AnnotationRenderer.measureText(annotation))
        let localCenter = CGPoint(
            x: padded.width * annotation.scaleX / 2,
            y: padded.height * annotation.scaleY / 2
        )
        return AnnotationRenderer.localToCanvas(
            localCenter, origin: annotation.position, angle: annotation.rotation
        )
    }
}

// MARK: - Supporting Types

private struct EditingState {
    let id: UUID
    let originalText: String
}

enum HandleMode {
    case resize
    case rotate
}

/// Which axis a text scaling operation affects.
private enum ScaleAxis {
    case uniform    // corner handles — both axes
    case horizontal // left/right handles
    case vertical   // top/bottom handles
}

/// Which endpoints of an arrow follow a translation drag.
private struct ArrowEndpointMask: OptionSet {
    let rawValue: Int
    static let start = ArrowEndpointMask(rawValue: 1 << 0)
    static let end   = ArrowEndpointMask(rawValue: 1 << 1)
    static let both: ArrowEndpointMask = [.start, .end]
}

private enum DragOperation {
    case none
    case creatingArrow(start: CGPoint, end: CGPoint)
    case creatingRectangle(start: CGPoint, end: CGPoint)
    case croppingSelection(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint, mask: ArrowEndpointMask)
    case movingRectangle(id: UUID, initialRect: CGRect)
    case resizingRectangle(id: UUID, initialRect: CGRect, handle: HandlePosition)
    case movingText(id: UUID, initialPosition: CGPoint)
    case scalingText(
        id: UUID,
        axis: ScaleAxis,
        initialScaleX: CGFloat,
        initialScaleY: CGFloat,
        center: CGPoint,
        paddedWidth: CGFloat,
        paddedHeight: CGFloat,
        initialRef: CGFloat
    )
    case rotatingText(id: UUID, initialRotation: Double, referenceAngle: Double, center: CGPoint)
}

// MARK: - Helpers

/// Translates a point by a SwiftUI gesture translation.
private func + (point: CGPoint, translation: CGSize) -> CGPoint {
    CGPoint(x: point.x + translation.width, y: point.y + translation.height)
}

private extension Array where Element: Identifiable {
    /// Locates the element with the given id and applies an in-place mutation.
    /// Does nothing if no matching element exists.
    mutating func update(id: Element.ID, _ body: (inout Element) -> Void) {
        guard let i = firstIndex(where: { $0.id == id }) else { return }
        body(&self[i])
    }
}
