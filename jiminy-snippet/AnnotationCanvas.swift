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
    @State private var editingTextId: UUID?
    @State private var editingOriginalText: String?
    @FocusState private var focusedTextId: UUID?
    @State private var lastTapTime: Date?
    @State private var lastTapLocation: CGPoint?

    private var imageSize: CGSize { image.size }

    private var textSizes: [UUID: CGSize] {
        var sizes: [UUID: CGSize] = [:]
        for annotation in texts {
            sizes[annotation.id] = AnnotationRenderer.measureText(annotation)
        }
        return sizes
    }

    var body: some View {
        GeometryReader { _ in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Canvas draws image + all annotations
                    annotationCanvas

                    // Gesture overlay
                    gestureLayer

                    // Click-catcher to commit text editing
                    if editingTextId != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: imageSize.width, height: imageSize.height)
                            .onTapGesture {
                                if let id = editingTextId {
                                    commitTextEditing(id: id)
                                    focusedTextId = nil
                                }
                            }
                    }

                    // TextField overlay for editing text
                    if let editingId = editingTextId,
                       let annotation = texts.first(where: { $0.id == editingId }) {
                        textFieldOverlay(for: annotation)
                    }
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .scaleEffect(scale)
                .frame(
                    width: imageSize.width * scale,
                    height: imageSize.height * scale
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Canvas

    private var annotationCanvas: some View {
        Canvas { context, _ in
            // Draw the base image
            context.draw(
                Image(nsImage: image),
                in: CGRect(origin: .zero, size: imageSize)
            )

            // Draw arrows
            for arrow in arrows {
                let selected = selectedAnnotationId == arrow.id
                AnnotationRenderer.drawArrow(arrow, selected: selected, in: &context)
            }

            // Draw text annotations (skip the one being edited)
            for annotation in texts where annotation.id != editingTextId {
                let (resolved, size) = AnnotationRenderer.resolveText(annotation, in: context)
                AnnotationRenderer.drawText(annotation, resolved: resolved, size: size, in: &context)
                if selectedAnnotationId == annotation.id {
                    AnnotationRenderer.drawTextSelection(annotation, size: size, in: &context)
                }
            }

            // Arrow creation preview
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
            .allowsHitTesting(editingTextId == nil)
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
            .rotationEffect(.degrees(annotation.rotation), anchor: .topLeading)
            .offset(x: annotation.position.x, y: annotation.position.y)
            .onAppear { focusedTextId = annotationId }
            .onSubmit {
                commitTextEditing(id: annotationId)
                focusedTextId = nil
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
            // First drag event — determine what we're doing
            let startPoint = value.startLocation

            if selectedTool == .arrow {
                dragOperation = .creatingArrow(start: startPoint, end: point)
                return
            }

            if let hit = hitTestAnnotations(
                at: startPoint, arrows: arrows, texts: texts,
                selectedId: selectedAnnotationId, textSizes: textSizes
            ) {
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
                        case .resizeHandle:
                            dragOperation = .resizingText(id: id, initialFontSize: annotation.fontSize)
                        case .body:
                            dragOperation = .movingText(id: id, initialPosition: annotation.position)
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

        case .resizingText(let id, let initialFontSize):
            if let index = texts.firstIndex(where: { $0.id == id }) {
                let diagonal = translation.width + translation.height
                let scaleFactor = 1.0 + diagonal / 150.0
                texts[index].fontSize = min(200, max(8, initialFontSize * scaleFactor))
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
            // Double tap
            lastTapTime = nil
            lastTapLocation = nil
            handleDoubleTap(at: location)
            return
        }
        lastTapTime = now
        lastTapLocation = location

        // Single tap
        if selectedTool == .text {
            createTextAnnotation(at: location)
            return
        }

        if let hit = hitTestAnnotations(
            at: location, arrows: arrows, texts: texts,
            selectedId: selectedAnnotationId, textSizes: textSizes
        ) {
            switch hit {
            case .arrow(let id, _): selectedAnnotationId = id
            case .text(let id, _): selectedAnnotationId = id
            }
        } else {
            selectedAnnotationId = nil
        }
    }

    private func handleDoubleTap(at location: CGPoint) {
        if let hit = hitTestAnnotations(
            at: location, arrows: arrows, texts: texts,
            selectedId: selectedAnnotationId, textSizes: textSizes
        ) {
            if case .text(let id, _) = hit {
                startEditing(id: id)
            }
        }
    }

    // MARK: - Text Editing

    private func createTextAnnotation(at location: CGPoint) {
        if let editingId = editingTextId {
            commitTextEditing(id: editingId)
            focusedTextId = nil
        }

        let annotation = TextAnnotation(
            position: location,
            text: "",
            color: selectedColor,
            isEditing: true
        )
        texts.append(annotation)
        editingOriginalText = ""
        editingTextId = annotation.id
        focusedTextId = annotation.id
        selectedAnnotationId = annotation.id
        selectedTool = nil
    }

    private func startEditing(id: UUID) {
        guard let annotation = texts.first(where: { $0.id == id }) else { return }
        editingOriginalText = annotation.text
        editingTextId = id
        selectedAnnotationId = id
        if let index = texts.firstIndex(where: { $0.id == id }) {
            texts[index].isEditing = true
        }
    }

    private func commitTextEditing(id: UUID) {
        if let index = texts.firstIndex(where: { $0.id == id }) {
            if texts[index].text.isEmpty {
                texts.remove(at: index)
            } else {
                texts[index].isEditing = false
            }
        }
        editingTextId = nil
        editingOriginalText = nil
    }

    private func cancelTextEditing(id: UUID) {
        if let index = texts.firstIndex(where: { $0.id == id }) {
            if let original = editingOriginalText, !original.isEmpty {
                texts[index].text = original
                texts[index].isEditing = false
            } else {
                texts.remove(at: index)
            }
        }
        editingTextId = nil
        editingOriginalText = nil
        focusedTextId = nil
    }

}

// MARK: - Drag Operation

enum DragOperation {
    case none
    case creatingArrow(start: CGPoint, end: CGPoint)
    case movingArrow(id: UUID, initialStart: CGPoint, initialEnd: CGPoint)
    case movingArrowStart(id: UUID, initialStart: CGPoint)
    case movingArrowEnd(id: UUID, initialEnd: CGPoint)
    case movingText(id: UUID, initialPosition: CGPoint)
    case resizingText(id: UUID, initialFontSize: CGFloat)
}
