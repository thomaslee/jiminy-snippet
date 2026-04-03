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
                    width: imageSize.width * scale,
                    height: imageSize.height * scale
                )
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationId, editingTextId == nil else {
            return
        }
        if let index = arrows.firstIndex(where: { $0.id == id }) {
            arrows.remove(at: index)
            selectedAnnotationId = nil
        } else if let index = texts.firstIndex(where: { $0.id == id }) {
            texts.remove(at: index)
            selectedAnnotationId = nil
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
                texts[index].isEditing = false
            }
        }
        editingTextId = nil
        editingOriginalText = nil
        focusedTextId = nil

        // Remove empty texts after state has settled
        DispatchQueue.main.async {
            texts.removeAll { $0.text.isEmpty }
        }
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

        ForEach($texts) { $annotation in
            textAnnotationView(annotation: $annotation)
        }
    }

    // MARK: - Text Annotation Views

    @ViewBuilder
    private func textAnnotationView(annotation: Binding<TextAnnotation>) -> some View {
        if editingTextId == annotation.wrappedValue.id {
            let annotationId = annotation.wrappedValue.id
            TextField("Type here", text: annotation.text)
                .font(.system(size: annotation.wrappedValue.fontSize, weight: .bold))
                .foregroundStyle(annotation.wrappedValue.color)
                .textFieldStyle(.plain)
                .fixedSize()
                .focused($focusedTextId, equals: annotationId)
                .offset(x: annotation.wrappedValue.position.x,
                        y: annotation.wrappedValue.position.y)
                .onAppear {
                    focusedTextId = annotationId
                }
                .onSubmit {
                    if annotation.wrappedValue.text.isEmpty {
                        texts.removeAll { $0.id == annotation.wrappedValue.id }
                    }
                    annotation.wrappedValue.isEditing = false
                    editingTextId = nil
                    editingOriginalText = nil
                    focusedTextId = nil
                }
                .onExitCommand {
                    cancelTextEditing(id: annotation.wrappedValue.id)
                }
        } else {
            DraggableTextView(
                annotation: annotation,
                selectedTool: selectedTool,
                isSelected: selectedAnnotationId == annotation.wrappedValue.id,
                onSelect: { selectedAnnotationId = annotation.wrappedValue.id },
                onStartEditing: {
                    editingOriginalText = annotation.wrappedValue.text
                    editingTextId = annotation.wrappedValue.id
                    selectedAnnotationId = annotation.wrappedValue.id
                    annotation.wrappedValue.isEditing = true
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
                if let index = texts.firstIndex(where: { $0.id == editingId }) {
                    if texts[index].text.isEmpty {
                        texts.remove(at: index)
                    } else {
                        texts[index].isEditing = false
                    }
                }
                editingTextId = nil
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

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else { return path }

        let angle = atan2(dy, dx)
        let headLength: CGFloat = min(20, length * 0.3)
        let headAngle: CGFloat = .pi / 6

        let p1 = CGPoint(
            x: end.x - headLength * cos(angle - headAngle),
            y: end.y - headLength * sin(angle - headAngle)
        )
        let p2 = CGPoint(
            x: end.x - headLength * cos(angle + headAngle),
            y: end.y - headLength * sin(angle + headAngle)
        )

        path.move(to: p1)
        path.addLine(to: end)
        path.addLine(to: p2)

        return path
    }
}
