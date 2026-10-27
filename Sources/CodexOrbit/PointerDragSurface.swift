import AppKit
import SwiftUI

/// Native pointer tracking avoids SwiftUI Button/DragGesture competition and
/// keeps the press origin stable while the borderless window follows the pointer.
struct PointerDragSurface: NSViewRepresentable {
    var clicked: () -> Void
    var dragged: (NSPoint, NSPoint) -> Void
    var ended: () -> Void

    func makeNSView(context: Context) -> PointerDragView { PointerDragView() }
    func updateNSView(_ view: PointerDragView, context: Context) {
        view.clicked = clicked; view.dragged = dragged; view.ended = ended
    }
}

final class PointerDragView: NSView {
    var clicked: () -> Void = {}
    var dragged: (NSPoint, NSPoint) -> Void = { _, _ in }
    var ended: () -> Void = {}
    private var press: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let SwiftUI's existing context menu receive secondary clicks.
        if let event = NSApp.currentEvent {
            let secondary = event.type == .rightMouseDown || event.type == .rightMouseUp || event.type == .rightMouseDragged
            let controlClick = event.modifierFlags.contains(.control) &&
                (event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .leftMouseDragged)
            if secondary || controlClick { return nil }
        }
        return super.hitTest(point)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        press = screenPoint(event); isDragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = press else { return }
        let point = screenPoint(event)
        if !isDragging, hypot(point.x - start.x, point.y - start.y) >= 4 { isDragging = true }
        if isDragging { NSCursor.closedHand.set(); dragged(start, point) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let start = press else { return }
        let moved = isDragging
        press = nil; isDragging = false
        if moved { dragged(start, screenPoint(event)); ended() }
        else { clicked() }
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }
}
