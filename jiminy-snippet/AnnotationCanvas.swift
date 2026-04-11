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

                    if editing != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: imageSize.width, height: imageSize.height)
                            .onTapGesture {
                                if let id = editing?.id {
                                    commitTextEditing(id: id)
                                }
                            }
                    }

                    if let editingId = editing?.id,
                       let annotation = texts.first(where: { $0.id == editingId }) {
                        textFieldOverlay(for: annotation)
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
        if let index = arrows.firstIndex(where: { $0.id == id }) {
            arrows.remove(at: index)
        } else if let index = texts.firstIndex(where: { $0.id == id }) {
            texts.remove(at: index)
        }
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
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .allowsHitTesting(false)
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

    // MARK: - TextField Overlay

    private func textFieldOverlay(for annotation: TextAnnotation) -> some View {
        let annotationId = annotation.id
        let textBinding = Binding<String>(
            get: { texts.first(where: { $0.id == annotationId })?.text ?? "" },
            set: { newValue in
                if let index = texts.firstIndex(where: { $0.id == annotationId }) {
                    texts[index].text = newValue
                }
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
            let startPoint = value.startLocation

            if selectedTool == .arrow {
                selectedAnnotationId = nil
                dragOperation = .creatingArrow(start: startPoint, end: point)
                return
            }

            if let hit = hitTest(at: startPoint) {
                switch hit {
                case .arrow(let id, let zone):
                    selectedAnnotationId = id
                    if let arrow = arrows.first(where: { $0.id == id }) {
                        switch zone {
                        case .startEndpoint:
                            dragOperation = .movingArrowStart(id: id, initialStart: arrow.start)
                        case .endEndpoint:
                            dragOperation = .movingArrowEnd(id: id, initialEnd: arrow.end)
                        case .body:
                            dragOperation = .movingArrow(
                                id: id, initialStart: arrow.start, initialEnd: arrow.end
                            )
                        default: break
                        }
                    }
                case .text(let id, let zone):
                    selectedAnnotationId = id
                    if let annotation = texts.first(where: { $0.id == id }) {
                        switch zone {
                        case .handle(let handlePos):
                            let size = textSizes[id] ?? .zero
                            let padded = RenderConstants.paddedTextSize(size)
                            let scaledSize = CGSize(
                                width: padded.width * annotation.scaleX,
                                height: padded.height * annotation.scaleY
                            )
                            let center = textCenter(for: annotation)

                            if handleMode == .rotate {
                                dragOperation = beginRotation(for: annotation, from: startPoint)
                            } else {
                                let axis: ScaleAxis
                                let initialRef: CGFloat
                                if handlePos.isCorner {
                                    axis = .uniform
                                    let handleLocal = handlePos.localPoint(scaledSize: scaledSize)
                                    let handleCanvas = AnnotationRenderer.localToCanvas(
                                        handleLocal, origin: annotation.position,
                                        angle: annotation.rotation
                                    )
                                    initialRef = hypot(
                                        handleCanvas.x - center.x,
                                        handleCanvas.y - center.y
                                    )
                                } else if handlePos == .left || handlePos == .right {
                                    axis = .horizontal
                                    initialRef = padded.width * annotation.scaleX / 2
                                } else {
                                    axis = .vertical
                                    initialRef = padded.height * annotation.scaleY / 2
                                }
                                dragOperation = .scalingText(
                                    id: id,
                                    axis: axis,
                                    initialScaleX: annotation.scaleX,
                                    initialScaleY: annotation.scaleY,
                                    center: center,
                                    paddedWidth: padded.width,
                                    paddedHeight: padded.height,
                                    initialRef: initialRef
                                )
                            }
                        case .body:
                            dragOperation = .movingText(id: id, initialPosition: annotation.position)
                        case .exterior:
                            if handleMode == .rotate {
                                dragOperation = beginRotation(for: annotation, from: startPoint)
                            }
                        default: break
                        }
                    }
                }
            }

        case .creatingArrow(let start, _):
            dragOperation = .creatingArrow(start: start, end: point)

        case .movingArrow(let id, let initialStart, let initialEnd):
            if let index = arrows.firstIndex(where: { $0.id == id }) {
                arrows[index].start = CGPoint(
                    x: initialStart.x + translation.width,
                    y: initialStart.y + translation.height
                )
                arrows[index].end = CGPoint(
                    x: initialEnd.x + translation.width,
                    y: initialEnd.y + translation.height
                )
            }

        case .movingArrowStart(let id, let initial):
            if let index = arrows.firstIndex(where: { $0.id == id }) {
                arrows[index].start = CGPoint(
                    x: initial.x + translation.width,
                    y: initial.y + translation.height
                )
            }

        case .movingArrowEnd(let id, let initial):
            if let index = arrows.firstIndex(where: { $0.id == id }) {
                arrows[index].end = CGPoint(
                    x: initial.x + translation.width,
                    y: initial.y + translation.height
                )
            }

        case .movingText(let id, let initial):
            if let index = texts.firstIndex(where: { $0.id == id }) {
                texts[index].position = CGPoint(
                    x: initial.x + translation.width,
                    y: initial.y + translation.height
                )
            }

        case .scalingText(let id, let axis, let initialScaleX, let initialScaleY,
                         let center, let paddedWidth, let paddedHeight, let initialRef):
            guard initialRef > 0.001,
                  let index = texts.firstIndex(where: { $0.id == id }) else { break }
            let rad = texts[index].rotation * .pi / 180
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
            texts[index].scaleX = newSX
            texts[index].scaleY = newSY

            // Reposition so center stays fixed
            let newLocalCenter = CGPoint(
                x: paddedWidth * newSX / 2,
                y: paddedHeight * newSY / 2
            )
            texts[index].position = CGPoint(
                x: center.x - (newLocalCenter.x * cos(rad) - newLocalCenter.y * sin(rad)),
                y: center.y - (newLocalCenter.x * sin(rad) + newLocalCenter.y * cos(rad))
            )

        case .rotatingText(let id, let initialRotation, let referenceAngle, let center):
            if let index = texts.firstIndex(where: { $0.id == id }) {
                let currentAngle = atan2(
                    point.y - center.y, point.x - center.x
                ) * 180 / .pi
                texts[index].rotation = initialRotation + (currentAngle - referenceAngle)
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        if case .creatingArrow(let start, _) = dragOperation {
            let end = value.location
            let arrow = ArrowAnnotation(start: start, end: end, color: selectedColor)
            arrows.append(arrow)
            selectedTool = nil
        }
        dragOperation = .none
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint) {
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

    /// Returns the center of a text annotation's scaled bounding box in canvas space.
    private func textCenter(for annotation: TextAnnotation) -> CGPoint {
        let size = textSizes[annotation.id] ?? .zero
        let padded = RenderConstants.paddedTextSize(size)
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

private enum DragOperation {
    case none
    case creatingArrow(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint)
    case movingArrowStart(id: UUID, initialStart: CGPoint)
    case movingArrowEnd(id: UUID, initialEnd: CGPoint)
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
