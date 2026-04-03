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
    let selectedTool: AnnotationTool
    let selectedColor: Color
    let scale: CGFloat
    let rotation: Double

    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var editingTextId: UUID?
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

                    annotationsOverlay

                    if selectedTool == .arrow, let start = dragStart, let end = dragEnd {
                        ArrowShape(start: start, end: end)
                            .stroke(selectedColor, lineWidth: 4)
                    }

                    interactionLayer
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

    @ViewBuilder
    private var annotationsOverlay: some View {
        ForEach(arrows) { arrow in
            ArrowShape(start: arrow.start, end: arrow.end)
                .stroke(arrow.color, lineWidth: arrow.lineWidth)
        }

        ForEach($texts) { $annotation in
            textAnnotationView(annotation: $annotation)
        }
    }

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
                .position(annotation.wrappedValue.position)
                .onAppear {
                    focusedTextId = annotationId
                }
                .onSubmit {
                    if annotation.wrappedValue.text.isEmpty {
                        texts.removeAll { $0.id == annotation.wrappedValue.id }
                    }
                    annotation.wrappedValue.isEditing = false
                    editingTextId = nil
                    focusedTextId = nil
                }
        } else {
            Text(annotation.wrappedValue.text.isEmpty ? " " : annotation.wrappedValue.text)
                .font(.system(size: annotation.wrappedValue.fontSize, weight: .bold))
                .foregroundStyle(annotation.wrappedValue.color)
                .fixedSize()
                .position(annotation.wrappedValue.position)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 1, y: 1)
                .onTapGesture {
                    if selectedTool == .text {
                        editingTextId = annotation.wrappedValue.id
                        annotation.wrappedValue.isEditing = true
                    }
                }
        }
    }

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
                        }
                        dragStart = nil
                        dragEnd = nil
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
            editingTextId = annotation.id
            focusedTextId = annotation.id
        }
    }
}

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
