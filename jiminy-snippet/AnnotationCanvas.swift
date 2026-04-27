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
    @Binding var arrows: [ArrowAnnotation]
    @Binding var texts: [TextAnnotation]
    @Binding var rectangles: [RectangleAnnotation]
    @Binding var selectedTool: AnnotationTool?
    @Binding var selectedAnnotationIds: Set<UUID>
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
    /// Invoked when the user finishes drawing a pixelate region. The owner
    /// burns the rect into the underlying image — pixelation is destructive
    /// by design so a redacted area can't later be moved or deleted.
    var onApplyPixelate: (CGRect) -> Void = { _ in }

    // MARK: - Gesture State

    @State private var dragOperation: DragOperation = .none
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
        for annotation in texts {
            sizes[annotation.id] = AnnotationRenderer.measureText(annotation)
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
            at: point, arrows: arrows, texts: texts, rectangles: rectangles,
            selectedId: singleSelectedId, textSizes: textSizes
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
                deleteSelectedAnnotations()
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

    private func deleteSelectedAnnotations() {
        let ids = selectedAnnotationIds
        let hasAny = arrows.contains(where: { ids.contains($0.id) })
            || texts.contains(where: { ids.contains($0.id) })
            || rectangles.contains(where: { ids.contains($0.id) })
        guard hasAny else { return }
        onBeginEdit()
        arrows.removeAll { ids.contains($0.id) }
        texts.removeAll { ids.contains($0.id) }
        rectangles.removeAll { ids.contains($0.id) }
        selectedAnnotationIds.removeAll()
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

            for arrow in arrows {
                let selected = selectedAnnotationIds.contains(arrow.id)
                AnnotationRenderer.drawArrow(
                    arrow,
                    selected: selected,
                    showHandles: selected && isSingleSelection,
                    in: &context
                )
            }

            for rectangle in rectangles {
                let selected = selectedAnnotationIds.contains(rectangle.id)
                AnnotationRenderer.drawRectangle(
                    rectangle,
                    selected: selected,
                    showHandles: selected && isSingleSelection,
                    in: &context
                )
            }

            for annotation in texts where annotation.id != editing?.id {
                let (resolved, size) = AnnotationRenderer.resolveText(annotation, in: context)
                AnnotationRenderer.drawText(annotation, resolved: resolved, size: size, in: &context)
                if selectedAnnotationIds.contains(annotation.id) {
                    AnnotationRenderer.drawTextSelection(
                        annotation,
                        size: size,
                        showHandles: isSingleSelection,
                        in: &context
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
                AnnotationRenderer.drawRectangle(draft, selected: false, showHandles: false, in: &context)
            }

            if case .creatingPixelate(let start, let end) = dragOperation {
                let rect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )
                AnnotationRenderer.drawPixelatePreview(
                    rect: rect,
                    pixelatedSource: pixelatedImage,
                    canvasScale: scale,
                    in: &context
                )
            }

            if cropMode {
                drawCropOverlay(in: &context)
            }

            if case .marqueeSelecting(let start, let end, _, _) = dragOperation {
                drawMarquee(start: start, end: end, in: &context)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(false)
    }

    private func marqueeRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Translucent fill plus a 1-device-pixel dashed outline. Stroke width is
    /// inverse-scaled so the marquee reads the same regardless of zoom.
    private func drawMarquee(start: CGPoint, end: CGPoint, in context: inout GraphicsContext) {
        let rect = marqueeRect(start: start, end: end)
        let path = Path(rect)
        context.fill(path, with: .color(.accentColor.opacity(0.12)))
        let lineWidth = 1.0 / max(scale, 0.1)
        context.stroke(
            path,
            with: .color(.accentColor.opacity(0.85)),
            style: StrokeStyle(lineWidth: lineWidth, dash: [4 * lineWidth, 3 * lineWidth])
        )
    }

    /// Returns the ids of every annotation whose axis-aligned bounding box
    /// intersects `rect`. Touching counts (Finder-style), so a marquee that
    /// merely grazes the edge of an annotation is enough to select it.
    private func annotationsIntersecting(_ rect: CGRect) -> Set<UUID> {
        var ids: Set<UUID> = []
        for arrow in arrows where arrowBoundingBox(arrow).intersects(rect) {
            ids.insert(arrow.id)
        }
        for rectangle in rectangles where rectangleBoundingBox(rectangle).intersects(rect) {
            ids.insert(rectangle.id)
        }
        for text in texts where textBoundingBox(text).intersects(rect) {
            ids.insert(text.id)
        }
        return ids
    }

    private func arrowBoundingBox(_ arrow: ArrowAnnotation) -> CGRect {
        let minX = min(arrow.start.x, arrow.end.x)
        let minY = min(arrow.start.y, arrow.end.y)
        let maxX = max(arrow.start.x, arrow.end.x)
        let maxY = max(arrow.start.y, arrow.end.y)
        // Pad to roughly the arrow head's half-width so the marquee picks up
        // the full visual extent of the arrow rather than just the centerline.
        let pad = arrow.lineWidth * 3.2
        return CGRect(
            x: minX - pad, y: minY - pad,
            width: (maxX - minX) + pad * 2, height: (maxY - minY) + pad * 2
        )
    }

    private func rectangleBoundingBox(_ rectangle: RectangleAnnotation) -> CGRect {
        let bounds = rectangle.rect.standardized
        guard rectangle.rotation != 0 else { return bounds }
        let rad = rectangle.rotation * .pi / 180
        let cosA = abs(cos(rad))
        let sinA = abs(sin(rad))
        let w = bounds.width * cosA + bounds.height * sinA
        let h = bounds.width * sinA + bounds.height * cosA
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    private func textBoundingBox(_ annotation: TextAnnotation) -> CGRect {
        let measured = AnnotationRenderer.measureText(annotation)
        let padded = RenderConstants.paddedTextSize(measured)
        let scaledSize = CGSize(
            width: padded.width * annotation.scaleX,
            height: padded.height * annotation.scaleY
        )
        let origin = annotation.position
        guard annotation.rotation != 0 else {
            return CGRect(origin: origin, size: scaledSize)
        }
        let rad = annotation.rotation * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let corners: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: scaledSize.width, y: 0),
            CGPoint(x: scaledSize.width, y: scaledSize.height),
            CGPoint(x: 0, y: scaledSize.height),
        ]
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for c in corners {
            let x = origin.x + c.x * cosA - c.y * sinA
            let y = origin.y + c.x * sinA + c.y * cosA
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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

        case .creatingPixelate(let start, _):
            dragOperation = .creatingPixelate(start: start, end: point)

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

        case .resizingRectangle(let id, let initial, let handle, let rotation):
            // Project the canvas-space drag translation into the rect's local
            // rotated frame so dragging the "right" handle moves along the
            // rect's local x axis even when the rect is at a non-zero angle.
            let rad = -rotation * .pi / 180
            let cosA = cos(rad), sinA = sin(rad)
            let localTrans = CGSize(
                width:  translation.width * cosA - translation.height * sinA,
                height: translation.width * sinA + translation.height * cosA
            )
            rectangles.update(id: id) {
                $0.rect = resizedRotatedRect(
                    initial: initial, rotation: rotation,
                    handle: handle, localTranslation: localTrans
                )
            }

        case .rotatingRectangle(let id, let initialRotation, let referenceAngle, let center):
            rectangles.update(id: id) { rectangle in
                let currentAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
                let raw = initialRotation + (currentAngle - referenceAngle)
                rectangle.rotation = snappedRotation(raw)
                // `rect` is the unrotated bounds and the renderer pivots
                // around its center, so leaving `rect` untouched keeps the
                // rotation anchored at `center`.
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

        case .marqueeSelecting(let start, _, let initialSelection, let additive):
            let rect = marqueeRect(start: start, end: point)
            let inside = annotationsIntersecting(rect)
            selectedAnnotationIds = additive
                ? initialSelection.union(inside)
                : inside
            dragOperation = .marqueeSelecting(
                start: start, end: point,
                initialSelection: initialSelection, additive: additive
            )

        case .movingMultiple(let initialArrows, let initialTexts, let initialRectangles):
            for (id, initial) in initialArrows {
                arrows.update(id: id) { arrow in
                    arrow.start = initial.start + translation
                    arrow.end = initial.end + translation
                }
            }
            for (id, initialPos) in initialTexts {
                texts.update(id: id) { $0.position = initialPos + translation }
            }
            for (id, initialRect) in initialRectangles {
                rectangles.update(id: id) {
                    $0.rect = initialRect.offsetBy(
                        dx: translation.width, dy: translation.height
                    )
                }
            }

        case .rotatingText(let id, let initialRotation, let referenceAngle, let center,
                           let paddedWidth, let paddedHeight, let scaleX, let scaleY):
            texts.update(id: id) { text in
                let currentAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
                let newRotation = snappedRotation(initialRotation + (currentAngle - referenceAngle))
                text.rotation = newRotation

                // The renderer pivots around `position` (the box's top-left),
                // so rotating in place would whip the text around that corner.
                // Recompute `position` each frame so the box's visual center
                // stays pinned at `center` regardless of angle.
                let rad = newRotation * .pi / 180
                let halfW = paddedWidth * scaleX / 2
                let halfH = paddedHeight * scaleY / 2
                let cosA = cos(rad), sinA = sin(rad)
                text.position = CGPoint(
                    x: center.x - (halfW * cosA - halfH * sinA),
                    y: center.y - (halfW * sinA + halfH * cosA)
                )
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
            selectedAnnotationIds.removeAll()
            return .creatingArrow(start: startPoint, end: startPoint)
        }

        if selectedTool == .rectangle {
            selectedAnnotationIds.removeAll()
            return .creatingRectangle(start: startPoint, end: startPoint)
        }

        if selectedTool == .pixelate {
            selectedAnnotationIds.removeAll()
            return .creatingPixelate(start: startPoint, end: startPoint)
        }

        let isShift = NSEvent.modifierFlags.contains(.shift)

        // Empty-space drag = marquee selection. Shift makes it additive (extends
        // the existing selection); plain marquee replaces. Holding Option while
        // dragging from empty space takes the drag-out path instead, but that's
        // routed through DragOutHandle and never reaches this method.
        guard let hit = hitTest(at: startPoint) else {
            let initial = isShift ? selectedAnnotationIds : []
            if !isShift {
                selectedAnnotationIds.removeAll()
            }
            return .marqueeSelecting(
                start: startPoint, end: startPoint,
                initialSelection: initial, additive: isShift
            )
        }

        // Shift-drag on an annotation: bail. Shift is reserved for the click-
        // toggle behavior, and multi-selection drag of one item with shift held
        // would be ambiguous (toggle? augment? translate?). Rotation handles
        // are exempt — shift-drag from the rotate handle snaps to 45°.
        if isShift && !hit.isRotateHandle {
            return nil
        }

        // Body-drag on any member of a multi-selection moves the whole group
        // together. Handle drags don't reach this branch — handles aren't
        // drawn or hit-tested while multi-selected — so this is purely the
        // translate-as-a-unit case.
        let hitId = hit.id
        if hit.isBody, selectedAnnotationIds.contains(hitId), selectedAnnotationIds.count > 1 {
            return beginMovingMultiple()
        }

        switch hit {
        case .arrow(let id, let zone):
            selectedAnnotationIds = [id]
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
            selectedAnnotationIds = [id]
            guard let annotation = texts.first(where: { $0.id == id }) else { return nil }
            switch zone {
            case .handle(let handlePos):
                return beginTextScaling(for: annotation, handle: handlePos)
            case .rotateHandle:
                return beginRotation(for: annotation, from: startPoint)
            case .body:
                return .movingText(id: id, initialPosition: annotation.position)
            default:
                return nil
            }

        case .rectangle(let id, let zone):
            selectedAnnotationIds = [id]
            guard let rectangle = rectangles.first(where: { $0.id == id }) else { return nil }
            switch zone {
            case .body:
                return .movingRectangle(id: id, initialRect: rectangle.rect)
            case .handle(let handlePos):
                return .resizingRectangle(
                    id: id,
                    initialRect: rectangle.rect.standardized,
                    handle: handlePos,
                    rotation: rectangle.rotation
                )
            case .rotateHandle:
                return beginRectangleRotation(for: rectangle, from: startPoint)
            default:
                return nil
            }

        }
    }

    /// Snapshots every selected annotation's current geometry so a drag can
    /// translate them all from a stable base.
    private func beginMovingMultiple() -> DragOperation {
        let ids = selectedAnnotationIds
        var initialArrows: [UUID: (start: CGPoint, end: CGPoint)] = [:]
        var initialTexts: [UUID: CGPoint] = [:]
        var initialRectangles: [UUID: CGRect] = [:]
        for arrow in arrows where ids.contains(arrow.id) {
            initialArrows[arrow.id] = (arrow.start, arrow.end)
        }
        for text in texts where ids.contains(text.id) {
            initialTexts[text.id] = text.position
        }
        for rectangle in rectangles where ids.contains(rectangle.id) {
            initialRectangles[rectangle.id] = rectangle.rect
        }
        return .movingMultiple(
            arrows: initialArrows, texts: initialTexts, rectangles: initialRectangles
        )
    }

    /// Builds a `rotatingRectangle` drag operation anchored at the rect's
    /// visual center.
    private func beginRectangleRotation(
        for rectangle: RectangleAnnotation,
        from startPoint: CGPoint
    ) -> DragOperation {
        let bounds = rectangle.rect.standardized
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let referenceAngle = atan2(
            startPoint.y - center.y,
            startPoint.x - center.x
        ) * 180 / .pi
        return .rotatingRectangle(
            id: rectangle.id,
            initialRotation: rectangle.rotation,
            referenceAngle: referenceAngle,
            center: center
        )
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        if case .creatingArrow(let start, _) = dragOperation {
            let end = value.location
            let arrow = ArrowAnnotation(start: start, end: end, color: selectedColor)
            arrows.append(arrow)
            selectedAnnotationIds = [arrow.id]
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
                selectedAnnotationIds = [rectangle.id]
            }
            selectedTool = nil
        } else if case .creatingPixelate(let start, _) = dragOperation {
            let end = value.location
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            if rect.width > 1, rect.height > 1 {
                onApplyPixelate(rect)
            } else {
                // No region drawn — drop the snapshot taken at drag start so
                // an accidental click on the pixelate tool doesn't burn an
                // undo slot.
                onDiscardEdit()
            }
            selectedTool = nil
        } else if case .resizingRectangle(let id, _, _, _) = dragOperation {
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

        onBeginEdit()
        let annotation = TextAnnotation(
            position: location,
            text: "",
            color: selectedColor
        )
        texts.append(annotation)
        editing = EditingState(id: annotation.id, originalText: "")
        focusedTextId = annotation.id
        selectedAnnotationIds = [annotation.id]
        selectedTool = nil
    }

    private func startEditing(id: UUID) {
        guard let annotation = texts.first(where: { $0.id == id }) else { return }
        onBeginEdit()
        editing = EditingState(id: id, originalText: annotation.text)
        selectedAnnotationIds = [id]
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

    /// If shift is held, snaps to the nearest 45° increment (0/45/90/...) so
    /// users can lock annotations to canvas-aligned angles. Otherwise returns
    /// `raw` unchanged.
    private func snappedRotation(_ raw: Double) -> Double {
        guard NSEvent.modifierFlags.contains(.shift) else { return raw }
        return (raw / 45).rounded() * 45
    }

    /// Builds a `rotatingText` drag operation anchored at the annotation's center.
    private func beginRotation(
        for annotation: TextAnnotation,
        from startPoint: CGPoint
    ) -> DragOperation {
        let padded = RenderConstants.paddedTextSize(AnnotationRenderer.measureText(annotation))
        let center = textCenter(for: annotation)
        let referenceAngle = atan2(
            startPoint.y - center.y,
            startPoint.x - center.x
        ) * 180 / .pi
        return .rotatingText(
            id: annotation.id,
            initialRotation: annotation.rotation,
            referenceAngle: referenceAngle,
            center: center,
            paddedWidth: padded.width,
            paddedHeight: padded.height,
            scaleX: annotation.scaleX,
            scaleY: annotation.scaleY
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

    /// Computes the new rect produced by dragging a handle on a rotated
    /// rectangle. `localTranslation` is the canvas-space drag delta already
    /// rotated into the rect's local frame, so handle math can be done as if
    /// the rect were axis-aligned. The result preserves the anchor (the
    /// edge/corner opposite to the dragged handle) at its canvas position.
    /// May be non-standardized while dragging past the opposite edge —
    /// callers standardize at the end of the drag.
    private func resizedRotatedRect(
        initial: CGRect,
        rotation: Double,
        handle: HandlePosition,
        localTranslation: CGSize
    ) -> CGRect {
        // Work in a local frame centred on the initial rect's center, where
        // the unrotated rect spans (-w/2 ... w/2, -h/2 ... h/2).
        let halfW = initial.width / 2
        let halfH = initial.height / 2
        var lMinX = -halfW, lMaxX = halfW
        var lMinY = -halfH, lMaxY = halfH

        let dx = localTranslation.width
        let dy = localTranslation.height
        switch handle {
        case .topLeft:     lMinX += dx; lMinY += dy
        case .top:                      lMinY += dy
        case .topRight:    lMaxX += dx; lMinY += dy
        case .left:        lMinX += dx
        case .right:       lMaxX += dx
        case .bottomLeft:  lMinX += dx; lMaxY += dy
        case .bottom:                   lMaxY += dy
        case .bottomRight: lMaxX += dx; lMaxY += dy
        }

        let newWidth = lMaxX - lMinX
        let newHeight = lMaxY - lMinY
        // Local-frame center of the new rect, relative to the initial center.
        let localCenter = CGPoint(x: (lMinX + lMaxX) / 2, y: (lMinY + lMaxY) / 2)

        // Rotate the local center back into canvas space and add to the
        // initial center to find where the new rect's center should sit.
        let rad = rotation * .pi / 180
        let cosA = cos(rad), sinA = sin(rad)
        let initialCenter = CGPoint(x: initial.midX, y: initial.midY)
        let newCenter = CGPoint(
            x: initialCenter.x + localCenter.x * cosA - localCenter.y * sinA,
            y: initialCenter.y + localCenter.x * sinA + localCenter.y * cosA
        )

        return CGRect(
            x: newCenter.x - newWidth / 2,
            y: newCenter.y - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
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
    case creatingPixelate(start: CGPoint, end: CGPoint)
    case croppingSelection(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint, mask: ArrowEndpointMask)
    case movingRectangle(id: UUID, initialRect: CGRect)
    case resizingRectangle(
        id: UUID,
        initialRect: CGRect,
        handle: HandlePosition,
        rotation: Double
    )
    case rotatingRectangle(
        id: UUID,
        initialRotation: Double,
        referenceAngle: Double,
        center: CGPoint
    )
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
    case rotatingText(
        id: UUID,
        initialRotation: Double,
        referenceAngle: Double,
        center: CGPoint,
        paddedWidth: CGFloat,
        paddedHeight: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    )
    /// Translates several annotations together — the body-drag flavour of a
    /// multi-selection. Each entry stores the initial geometry so the drag
    /// translation can be applied from a stable base.
    case movingMultiple(
        arrows: [UUID: (start: CGPoint, end: CGPoint)],
        texts: [UUID: CGPoint],
        rectangles: [UUID: CGRect]
    )
    /// Drag-rectangle (marquee) for selecting annotations en masse. Live-
    /// updates `selectedAnnotationIds` as the user drags. `initialSelection`
    /// is the set carried over from before the drag — non-empty only when
    /// `additive` is true (Shift held), so plain marquees replace selection.
    case marqueeSelecting(
        start: CGPoint,
        end: CGPoint,
        initialSelection: Set<UUID>,
        additive: Bool
    )
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
