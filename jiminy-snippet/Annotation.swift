//
//  Annotation.swift
//  jiminy-snippet
//
//  Created by Tom on 4/2/26.
//

import SwiftUI

enum AnnotationTool: String, CaseIterable {
    case arrow = "Arrow"
    case text = "Text"

    var systemImage: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }
}

/// Computes the two wing points for an arrowhead at `tip` coming from `tail`.
/// Returns `nil` if the arrow has zero length.
func arrowHeadWings(tip: CGPoint, tail: CGPoint) -> (left: CGPoint, right: CGPoint)? {
    let dx = tip.x - tail.x
    let dy = tip.y - tail.y
    let length = hypot(dx, dy)
    guard length > 0 else { return nil }

    let angle = atan2(dy, dx)
    let headLength = min(20, length * 0.3)
    let headAngle: CGFloat = .pi / 6

    return (
        left: CGPoint(
            x: tip.x - headLength * cos(angle - headAngle),
            y: tip.y - headLength * sin(angle - headAngle)
        ),
        right: CGPoint(
            x: tip.x - headLength * cos(angle + headAngle),
            y: tip.y - headLength * sin(angle + headAngle)
        )
    )
}

struct ArrowAnnotation: Identifiable, Equatable {
    let id = UUID()
    var start: CGPoint
    var end: CGPoint
    var color: Color
    var lineWidth: CGFloat = 4
}

struct TextAnnotation: Identifiable, Equatable {
    let id = UUID()
    var position: CGPoint
    var text: String
    var color: Color
    var fontSize: CGFloat = 24
    var rotation: Double = 0
    var isEditing: Bool = false
}

struct AnnotationPalette {
    static let colors: [(name: String, color: Color)] = [
        ("Orange", Color(red: 1.0, green: 0.6, blue: 0.0)),
        ("Red", Color.red),
        ("Yellow", Color.yellow),
        ("Green", Color.green),
        ("Blue", Color.blue),
        ("Purple", Color.purple),
        ("White", Color.white),
        ("Black", Color.black),
    ]
}
