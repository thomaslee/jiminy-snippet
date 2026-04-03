//
//  ContentView.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(ScreenshotManager.self) private var screenshotManager

    @State private var selectedTool: AnnotationTool = .arrow
    @State private var selectedColorIndex: Int = 0
    @State private var scale: CGFloat = 1.0
    @State private var rotation: Double = 0

    @State private var arrows: [ArrowAnnotation] = []
    @State private var texts: [TextAnnotation] = []

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
                    selectedTool: selectedTool,
                    selectedColor: selectedColor,
                    scale: scale,
                    rotation: rotation
                )
            } else {
                emptyState
            }
        }
        .frame(minWidth: 800, minHeight: 600)
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
                // Not implemented
            }
            .disabled(true)
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
                    selectedTool = tool
                } label: {
                    Image(systemName: tool == .arrow ? "arrow.up.right" : "textformat")
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

    private var scaleControls: some View {
        HStack(spacing: 4) {
            Button {
                scale = max(minScale, scale - scaleStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(scale <= minScale)

            Text("\(Int(scale * 100))%")
                .frame(width: 48)
                .monospacedDigit()

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
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotation -= 90
                }
            } label: {
                Image(systemName: "rotate.left")
            }
            .help("Rotate counter-clockwise")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    rotation += 90
                }
            } label: {
                Image(systemName: "rotate.right")
            }
            .help("Rotate clockwise")
        }
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
}

#Preview {
    ContentView()
        .environment(ScreenshotManager())
}
