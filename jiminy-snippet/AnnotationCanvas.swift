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
    let rotation: Double

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var editingTextId: UUID?
    @State private var editingOriginalText: String?
    @FocusState private var focusedTextId: UUID?

    private var imageSize: CGSize {
        image.size
    }

    /// Image size after rotation, used for scroll view content sizing.
    private var rotatedImageSize: CGSize {
        let normalizedRotation = ((Int(rotation) % 360) + 360) % 360
        let isRotated90 = normalizedRotation == 90 || normalizedRotation == 270
        return isRotated90
            ? CGSize(width: imageSize.height, height: imageSize.width)
            : imageSize
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageSize.width, height: imageSize.height)

                    // Interaction layer for creating new annotations (below existing ones)
                    interactionLayer

                    // Existing annotations on top so their gestures win
                    annotationsOverlay

                    // Click-catching layer to commit text editing when clicking outside
                    if editingTextId != nil {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: imageSize.width, height: imageSize.height)
                            .onTapGesture {
                                if let editingId = editingTextId {
                                    commitTextEditing(id: editingId)
                                    focusedTextId = nil
                                }
                            }
                    }

                    // Arrow drawing preview (topmost so it's always visible)
                    if selectedTool == .arrow, let start = dragStart, let end = dragEnd {
                        ArrowShape(start: start, end: end)
                            .stroke(selectedColor, lineWidth: 4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: imageSize.width, height: imageSize.height)
                .scaleEffect(scale)
                .rotationEffect(.degrees(rotation))
                .frame(
                    width: rotatedImageSize.width * scale,
                    height: rotatedImageSize.height * scale
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Annotations Overlay

    @ViewBuilder
    private var annotationsOverlay: some View {
        ForEach(Array(arrows.enumerated()), id: \.element.id) { index, arrow in
            DraggableArrowView(
                arrow: arrow,
                isSelected: selectedAnnotationId == arrow.id,
                onSelect: { selectedAnnotationId = arrow.id },
                onMove: { newStart, newEnd in
                    arrows[index].start = newStart
                    arrows[index].end = newEnd
                }
            )
        }

        ForEach(texts) { annotation in
            textAnnotationView(for: annotation)
        }
    }

    // MARK: - Text Annotation Views

    private func bindingForText(id: UUID) -> Binding<TextAnnotation> {
        Binding(
            get: {
                texts.first(where: { $0.id == id })
                    ?? TextAnnotation(position: .zero, text: "", color: .clear)
            },
            set: { newValue in
                if let index = texts.firstIndex(where: { $0.id == id }) {
                    texts[index] = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func textAnnotationView(for annotation: TextAnnotation) -> some View {
        let annotationId = annotation.id
        if editingTextId == annotationId {
            let textBinding = Binding<String>(
                get: { texts.first(where: { $0.id == annotationId })?.text ?? "" },
                set: { newValue in
                    if let index = texts.firstIndex(where: { $0.id == annotationId }) {
                        texts[index].text = newValue
                    }
                }
            )
            TextField("Type here", text: textBinding)
                .font(.system(size: annotation.fontSize, weight: .bold))
                .foregroundStyle(annotation.color)
                .textFieldStyle(.plain)
                .fixedSize()
                .focused($focusedTextId, equals: annotationId)
                .offset(x: annotation.position.x,
                        y: annotation.position.y)
                .onAppear {
                    focusedTextId = annotationId
                }
                .onSubmit {
                    commitTextEditing(id: annotationId)
                    focusedTextId = nil
                }
                .onExitCommand {
                    cancelTextEditing(id: annotationId)
                }
        } else {
            DraggableTextView(
                annotation: bindingForText(id: annotationId),
                selectedTool: selectedTool,
                isSelected: selectedAnnotationId == annotationId,
                onSelect: { selectedAnnotationId = annotationId },
                onStartEditing: {
                    editingOriginalText = annotation.text
                    editingTextId = annotationId
                    selectedAnnotationId = annotationId
                    if let index = texts.firstIndex(where: { $0.id == annotationId }) {
                        texts[index].isEditing = true
                    }
                }
            )
        }
    }

    // MARK: - Interaction Layer (for creating new annotations)

    private var interactionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: imageSize.width, height: imageSize.height)
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard selectedTool == .arrow else { return }
                        if dragStart == nil {
                            dragStart = value.startLocation
                        }
                        dragEnd = value.location
                    }
                    .onEnded { value in
                        guard selectedTool == .arrow else { return }
                        if let start = dragStart {
                            let arrow = ArrowAnnotation(
                                start: start,
                                end: value.location,
                                color: selectedColor
                            )
                            arrows.append(arrow)
                            selectedTool = nil
                        }
                        dragStart = nil
                        dragEnd = nil
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        selectedAnnotationId = nil
                        handleTap(at: value.location)
                    }
            )
            .allowsHitTesting(editingTextId == nil)
    }

    private func handleTap(at location: CGPoint) {
        if selectedTool == .text {
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
            selectedTool = nil
        }
    }
}

// MARK: - Draggable Arrow View

struct DraggableArrowView: View {
    let arrow: ArrowAnnotation
    let isSelected: Bool
    let onSelect: () -> Void
    let onMove: (CGPoint, CGPoint) -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    private var currentStart: CGPoint {
        CGPoint(x: arrow.start.x + dragOffset.width, y: arrow.start.y + dragOffset.height)
    }

    private var currentEnd: CGPoint {
        CGPoint(x: arrow.end.x + dragOffset.width, y: arrow.end.y + dragOffset.height)
    }

    var body: some View {
        ZStack {
            // Selection highlight behind the arrow
            if isSelected {
                ArrowShape(start: currentStart, end: currentEnd)
                    .stroke(Color.accentColor.opacity(0.4), lineWidth: arrow.lineWidth + 8)
            }

            // Visible arrow
            ArrowShape(start: currentStart, end: currentEnd)
                .stroke(arrow.color, lineWidth: arrow.lineWidth)

            // Wide invisible hit area for dragging
            ArrowShape(start: currentStart, end: currentEnd)
                .stroke(Color.white.opacity(0.001), lineWidth: 20)
        }
        .contentShape(
            ArrowShape(start: currentStart, end: currentEnd)
                .stroke(style: StrokeStyle(lineWidth: 20))
        )
        .onTapGesture {
            onSelect()
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation
                    onSelect()
                }
                .onEnded { value in
                    onMove(currentStart, currentEnd)
                    dragOffset = .zero
                    isDragging = false
                }
        )
    }
}

// MARK: - Draggable Text View

struct DraggableTextView: View {
    @Binding var annotation: TextAnnotation
    let selectedTool: AnnotationTool?
    let isSelected: Bool
    let onSelect: () -> Void
    let onStartEditing: () -> Void

    @State private var dragOffset: CGSize = .zero
    @State private var lastTapTime: Date?

    private var currentPosition: CGPoint {
        CGPoint(
            x: annotation.position.x + dragOffset.width,
            y: annotation.position.y + dragOffset.height
        )
    }

    var body: some View {
        Text(annotation.text.isEmpty ? " " : annotation.text)
            .font(.system(size: annotation.fontSize, weight: .bold))
            .foregroundStyle(annotation.color)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            )
            .offset(x: currentPosition.x, y: currentPosition.y)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 1, y: 1)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        dragOffset = value.translation
                        onSelect()
                    }
                    .onEnded { value in
                        annotation.position = currentPosition
                        dragOffset = .zero
                    }
            )
            .onTapGesture {
                onSelect()
                let now = Date()
                if let last = lastTapTime,
                   now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
                    lastTapTime = nil
                    DispatchQueue.main.async {
                        onStartEditing()
                    }
                } else {
                    lastTapTime = now
                }
            }
    }
}

// MARK: - Arrow Shape

struct ArrowShape: Shape {
    var start: CGPoint
    var end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: start)
        path.addLine(to: end)

        if let wings = arrowHeadWings(tip: end, tail: start) {
            path.move(to: wings.left)
            path.addLine(to: end)
            path.addLine(to: wings.right)
        }

        return path
    }
}
