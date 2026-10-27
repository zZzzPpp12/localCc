import Foundation
import CoreGraphics
import Combine

enum DockEdge: String, Codable { case left, right }

enum EdgeDockGeometry {
    static let inset: CGFloat = 4
    static let tabSize = CGSize(width: 108, height: 56)
    static let detailsSize = CGSize(width: 372, height: 420)
    static let detailsGap: CGFloat = 6

    static func edge(of frame: CGRect, in visible: CGRect, tolerance: CGFloat = 24) -> DockEdge? {
        guard frame.intersection(visible).height > 0 else { return nil }
        let left = abs(frame.minX - visible.minX)
        let right = abs(visible.maxX - frame.maxX)
        guard min(left, right) <= tolerance else { return nil }
        return left < right ? .left : .right
    }

    static func nearestEdge(of frame: CGRect, in visible: CGRect) -> DockEdge {
        frame.midX < visible.midX ? .left : .right
    }

    static func expandedFrame(edge: DockEdge, visible: CGRect, size: CGSize, centerY: CGFloat, compact: Bool = false) -> CGRect {
        let x = edge == .left ? visible.minX + inset : visible.maxX - size.width - inset
        // When only the capsule is visible, its footprint determines the vertical
        // limits. The hidden orb is a position anchor and may extend off screen.
        let halfHeight = compact ? tabSize.height / 2 + 4 : size.height / 2
        let y = min(max(centerY, visible.minY + halfHeight), visible.maxY - halfHeight) - size.height / 2
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func tabFrame(edge: DockEdge, visible: CGRect, expanded: CGRect, scale _: Double) -> CGRect {
        // The compact provider row has a fixed footprint, independent of orb scale.
        let size = tabSize
        let x = edge == .left ? visible.minX : visible.maxX - size.width
        let y = min(max(expanded.midY - size.height / 2, visible.minY + 4), visible.maxY - size.height - 4)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    static func detailsFrame(edge: DockEdge, visible: CGRect, tab: CGRect) -> CGRect {
        let x = edge == .left ? tab.maxX + detailsGap : tab.minX - detailsGap - detailsSize.width
        let y = tab.midY - detailsSize.height / 2
        return CGRect(x: min(max(x, visible.minX + 4), visible.maxX - detailsSize.width - 4),
                      y: min(max(y, visible.minY + 4), visible.maxY - detailsSize.height - 4),
                      width: detailsSize.width, height: detailsSize.height)
    }

    static func pointerIsInsideSidebar(_ point: CGPoint, tab: CGRect, details: CGRect?) -> Bool {
        if tab.insetBy(dx: -2, dy: -3).contains(point) { return true }
        guard let details else { return false }
        if details.insetBy(dx: -2, dy: -3).contains(point) { return true }
        // Only the corridor between the two windows holds the popup open.
        let x = min(tab.maxX, details.maxX), right = max(tab.minX, details.minX)
        let y = max(tab.minY, details.minY), top = min(tab.maxY, details.maxY)
        guard right > x, top > y else { return false }
        return CGRect(x: x, y: y, width: right - x, height: top - y).insetBy(dx: -2, dy: -3).contains(point)
    }
}

struct EdgeDockProtection {
    var dragging = false
    var showingDetails = false
    var showingSettings = false
    var trackingMenu = false
    var holdsExpanded: Bool { dragging || showingDetails || showingSettings || trackingMenu }
}

@MainActor
final class EdgeDockState: ObservableObject {
    @Published var edge: DockEdge = .right
    @Published var isCollapsed = false
}
