//
//  UndoHistory.swift
//  jiminy-snippet
//
//  Created by Tom on 4/11/26.
//

import AppKit

/// Snapshot of the editable state of the canvas at a single point in time.
/// Captured before each discrete edit so that the operation can later be undone.
struct EditSnapshot {
    let image: NSImage
    let arrows: [ArrowAnnotation]
    let texts: [TextAnnotation]
}

/// Fixed-capacity undo stack. Oldest snapshots are dropped once the capacity is
/// reached so memory stays bounded even across long editing sessions.
struct UndoHistory {
    static let maxSize = 50

    private(set) var snapshots: [EditSnapshot] = []

    var isEmpty: Bool { snapshots.isEmpty }
    var count: Int { snapshots.count }

    mutating func push(_ snapshot: EditSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > Self.maxSize {
            snapshots.removeFirst(snapshots.count - Self.maxSize)
        }
    }

    mutating func pop() -> EditSnapshot? {
        snapshots.popLast()
    }

    mutating func clear() {
        snapshots.removeAll()
    }
}
