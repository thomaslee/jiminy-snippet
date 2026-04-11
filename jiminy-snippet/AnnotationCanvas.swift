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
    @Binding var selectedTool: AnnotationTool?
    @Binding var selectedAnnotationId: UUID?
    let selectedColor: Color
    let scale: CGFloat
    let cropMode: Bool
    @Binding var cropRect: CGRect?
    var onCropApply: () -> Void = {}
    var onCropCancel: () -> Void = {}

    // MARK: - Gesture State

    @State private var dragOperation: DragOperation = .none
    @State private var editing: EditingState?
    @FocusState private var focusedTextId: UUID?
    @State private var lastTapTime: Date?
    @State private var lastTapLocation: CGPoint?
    @State private var keyMonitor: Any?
    @State private var handleMode: HandleMode = .resize

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
            at: point, arrows: arrows, texts: texts,
            selectedId: selectedAnnotationId, textSizes: textSizes
        )
    }

    var body: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    annotationCanvas
                    gestureLayer

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
                .overlay(alignment: .topLeading) { cropControlsOverlay }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onChange(of: selectedAnnotationId) {
            handleMode = .resize
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                handleKeyDown(event)
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
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
        arrows.removeAll { $0.id == id }
        texts.removeAll { $0.id == id }
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
                let previewPath = AnnotationRenderer.arrowPath(start: start, end: end)
                context.stroke(
                    previewPath,
                    with: .color(selectedColor),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
            }

            if cropMode {
                drawCropOverlay(in: &context)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(false)
    }

    // MARK: - Crop Overlay

    @ViewBuilder
    private var cropControlsOverlay: some View {
        if cropMode, let rect = cropRect, !isCroppingDrag {
            let offset = cropControlsOffset(for: rect)
            HStack(spacing: 8) {
                Button("Cancel", role: .cancel) { onCropCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onCropApply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4)
            .fixedSize()
            .offset(x: offset.x, y: offset.y)
        }
    }

    /// Positions the Apply/Cancel pill so it stays inside the ScrollView's
    /// content frame — preferring just below the crop rect, but flipping above
    /// or tucking inside at the bottom when there isn't enough room.
    private func cropControlsOffset(for rect: CGRect) -> CGPoint {
        let padding: CGFloat = 8
        // Rough size of the pill; exact measurement isn't worth a GeometryReader.
        let estimatedWidth: CGFloat = 180
        let estimatedHeight: CGFloat = 44

        let contentWidth = imageSize.width * scale
        let contentHeight = imageSize.height * scale

        let belowY = rect.maxY * scale + padding
        let aboveY = rect.minY * scale - estimatedHeight - padding

        let y: CGFloat
        if belowY + estimatedHeight <= contentHeight {
            y = belowY
        } else if aboveY >= 0 {
            y = aboveY
        } else {
            y = max(0, contentHeight - estimatedHeight - padding)
        }

        let maxX = max(0, contentWidth - estimatedWidth)
        let x = max(0, min(maxX, rect.maxX * scale - estimatedWidth))
        return CGPoint(x: x, y: y)
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
            dragOperation = op
            // Re-enter so the current translation is applied immediately,
            // rather than waiting one frame for the next drag event.
            handleDragChanged(value)

        case .creatingArrow(let start, _):
            dragOperation = .creatingArrow(start: start, end: point)

        case .croppingSelection(let start, _):
            dragOperation = .croppingSelection(start: start, end: point)

        case .movingArrow(let id, let initialStart, let initialEnd, let mask):
            arrows.update(id: id) { arrow in
                if mask.contains(.start) { arrow.start = initialStart + translation }
                if mask.contains(.end)   { arrow.end   = initialEnd + translation }
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
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        if case .creatingArrow(let start, _) = dragOperation {
            let end = value.location
            let arrow = ArrowAnnotation(start: start, end: end, color: selectedColor)
            arrows.append(arrow)
            selectedTool = nil
        } else if case .croppingSelection(let start, _) = dragOperation {
            let end = value.location
            let imageBounds = CGRect(origin: .zero, size: imageSize)
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            ).intersection(imageBounds)
            cropRect = (rect.width > 1 && rect.height > 1) ? rect : nil
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
    case croppingSelection(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint, mask: ArrowEndpointMask)
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
