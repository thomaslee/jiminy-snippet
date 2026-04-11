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
    @State private var selectedAnnotationId: UUID? = nil
    @State private var scaleText: String = "100"

    private let scaleStep: CGFloat = 0.25
    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0

    private var selectedColor: Color {
        AnnotationPalette.colors[selectedColorIndex].color
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            if let image = screenshotManager.capturedImage {
                AnnotationCanvas(
                    image: image,
                    arrows: $arrows,
                    texts: $texts,
                    selectedTool: $selectedTool,
                    selectedAnnotationId: $selectedAnnotationId,
                    selectedColor: selectedColor,
                    scale: scale
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
            } else {
                emptyState
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .onChange(of: arrows) { markUnsaved() }
        .onChange(of: texts) { markUnsaved() }
        .onChange(of: screenshotManager.capturedImage) {
            markUnsaved()
            zoomToFit()
        }
        .focusedSceneValue(\.copyScene, screenshotManager.capturedImage == nil ? nil : { copyToClipboard() })
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
            captureMenu

            if screenshotManager.capturedImage != nil {
                Divider().frame(height: 24)
                toolPicker
                Divider().frame(height: 24)
                colorPicker
                Divider().frame(height: 24)
                scaleControls
                Divider().frame(height: 24)
                rotateControls
                Spacer()
                exportMenu
                undoButton
            }
        }
    }

    private var captureMenu: some View {
        Menu {
            Button("Fullscreen") {
                clearAnnotations()
                screenshotManager.captureFullscreen()
            }
            Button("Screen snap...") {
                clearAnnotations()
                screenshotManager.captureRegion()
            }
            Button("Timed screen snap...") {
                // Not implemented
            }
            .disabled(true)
        } label: {
            Label("Capture", systemImage: "camera")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases, id: \.self) { tool in
                Button {
                    selectedTool = selectedTool == tool ? nil : tool
                } label: {
                    Image(systemName: tool.systemImage)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .tint(selectedTool == tool ? .accentColor : nil)
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 4) {
            ForEach(Array(AnnotationPalette.colors.enumerated()), id: \.offset) { index, item in
                Button {
                    selectedColorIndex = index
                    if let id = selectedAnnotationId {
                        if let i = arrows.firstIndex(where: { $0.id == id }) {
                            arrows[i].color = item.color
                        } else if let i = texts.firstIndex(where: { $0.id == id }) {
                            texts[i].color = item.color
                        }
                    }
                } label: {
                    Circle()
                        .fill(item.color)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(
                                    index == selectedColorIndex
                                        ? Color.accentColor : Color.gray.opacity(0.3),
                                    lineWidth: index == selectedColorIndex ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(item.name)
            }
        }
    }

    private static let scalePresets: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

    private var scaleControls: some View {
        HStack(spacing: 4) {
            Button {
                scale = max(minScale, scale - scaleStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(scale <= minScale)

            HStack(spacing: 0) {
                TextField("", text: $scaleText)
                    .monospacedDigit()
                    .frame(width: 40)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .onSubmit { applyScaleText() }

                Text("%")
                    .foregroundStyle(.secondary)

                Menu {
                    Button("Fit") { zoomToFit() }
                    Divider()
                    ForEach(Self.scalePresets, id: \.self) { preset in
                        Button("\(Int(preset * 100))%") {
                            scale = preset
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .onChange(of: scale) {
                scaleText = "\(Int(scale * 100))"
            }

            Button {
                scale = min(maxScale, scale + scaleStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(scale >= maxScale)
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

    private var exportMenu: some View {
        Menu {
            Button("Save As...") {
                exportImage()
            }
            .keyboardShortcut("s", modifiers: [.command])
            Button("Copy to Clipboard") {
                copyToClipboard()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var undoButton: some View {
        Button {
            if !texts.isEmpty {
                texts.removeLast()
            } else if !arrows.isEmpty {
                arrows.removeLast()
            }
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .help("Undo last annotation")
        .disabled(arrows.isEmpty && texts.isEmpty)
    }

    private func clearAnnotations() {
        arrows.removeAll()
        texts.removeAll()
    }

    private func copyToClipboard() {
        guard let image = screenshotManager.capturedImage else { return }

        let rendered = ImageExporter.render(
            image: image,
            arrows: arrows,
            texts: texts
        )

        ImageExporter.copyToPasteboard(image: rendered)
    }

    private func exportImage() {
        guard let image = screenshotManager.capturedImage else { return }

        let rendered = ImageExporter.render(
            image: image,
            arrows: arrows,
            texts: texts
        )

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot.png"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if ImageExporter.save(image: rendered, to: url) {
            screenshotManager.hasUnsavedChanges = false
        }
    }

    private func applyScaleText() {
        let cleaned = scaleText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        if let value = Double(cleaned) {
            scale = clamp(CGFloat(value) / 100.0, min: minScale, max: maxScale)
        }
        scaleText = "\(Int(scale * 100))"
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

    private func rotateImageAndAnnotations(clockwise: Bool) {
        guard let image = screenshotManager.capturedImage else { return }
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

        selectedAnnotationId = nil
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

#Preview {
    ContentView()
        .environment(ScreenshotManager())
}
