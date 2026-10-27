import Foundation
import CoreGraphics

@main
struct EdgeDockTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: \(name)") }
        count += 1
    }
    static func main() {
        let visible = CGRect(x: 0, y: 40, width: 1920, height: 1016)
        let size = CGSize(width: 164, height: 176)
        let right = EdgeDockGeometry.expandedFrame(edge: .right, visible: visible, size: size, centerY: 500)
        check(visible.contains(right), "expanded right window fits work area")
        check(EdgeDockGeometry.edge(of: right, in: visible) == .right, "right edge detection")
        let left = EdgeDockGeometry.expandedFrame(edge: .left, visible: visible, size: size, centerY: 500)
        check(EdgeDockGeometry.edge(of: left, in: visible) == .left, "left edge detection")
        check(EdgeDockGeometry.edge(of: CGRect(x: 800, y: 400, width: 164, height: 176), in: visible) == nil, "middle of screen never hides")
        check(EdgeDockGeometry.edge(of: CGRect(x: 4, y: 2000, width: 164, height: 176), in: visible) == nil, "off-screen vertical position never docks")
        let tab = EdgeDockGeometry.tabFrame(edge: .right, visible: visible, expanded: right, scale: 1)
        check(visible.contains(tab), "collapsed tab fully visible")
        check(tab.maxX == visible.maxX && tab.width == 108 && tab.height == 56, "compact AI quota row attaches flush to edge")
        for work in [visible, CGRect(x: -2560, y: -100, width: 2560, height: 1400)] {
            for edge in [DockEdge.left, .right] {
                let anchor = EdgeDockGeometry.expandedFrame(edge: edge, visible: work, size: size, centerY: work.midY, compact: true)
                let handle = EdgeDockGeometry.handleFrame(edge: edge, visible: work, expanded: anchor)
                let revealed = EdgeDockGeometry.tabFrame(edge: edge, visible: work, expanded: anchor, scale: 1)
                check(work.contains(handle) && handle.size == EdgeDockGeometry.handleSize, "hidden entry stays entirely on its own display")
                check(edge == .left ? handle.minX == work.minX : handle.maxX == work.maxX, "hidden entry is flush with physical display edge")
                check(handle.midY == revealed.midY && handle.width < revealed.width, "reveal preserves height and reduces desktop footprint while hidden")
                let dormant = CGPoint(x: edge == .left ? revealed.maxX - 5 : revealed.minX + 5, y: revealed.midY)
                check(!EdgeDockGeometry.pointerIsInsideSidebar(dormant, tab: handle, details: nil), "hidden capsule does not intercept empty former area")
            }
        }
        let popup = EdgeDockGeometry.detailsFrame(edge: .right, visible: visible, tab: tab)
        for edge in [DockEdge.left, .right] {
            let full = EdgeDockGeometry.tabFrame(edge: edge, visible: visible, expanded: right, scale: 1)
            var previousWidth: CGFloat = 0
            for index in 0...20 {
                let progress = EdgeDockGeometry.slideEase(Double(index) / 20)
                let frame = EdgeDockGeometry.slideFrame(edge: edge, tab: full, progress: progress)
                check(visible.contains(frame) && frame.width >= previousWidth && frame.midY == full.midY, "slide stays on its display with monotonic width and fixed height")
                check(edge == .left ? frame.minX == full.minX : frame.maxX == full.maxX, "slide preserves the outer display edge")
                previousWidth = frame.width
            }
            check(EdgeDockGeometry.slideFrame(edge: edge, tab: full, progress: 0).size == EdgeDockGeometry.handleSize, "animation begins at the exact narrow entry")
            check(EdgeDockGeometry.slideFrame(edge: edge, tab: full, progress: 1) == full, "animation ends at the exact expanded capsule")
        }
        check(EdgeDockGeometry.slideEase(-1) == 0 && EdgeDockGeometry.slideEase(2) == 1 && EdgeDockGeometry.slideEase(0.5) == 0.5, "easing clamps endpoints without overshoot")
        check(visible.contains(popup) && popup.maxX < tab.minX, "right dock opens details on its inner left side")
        check(EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: visible.maxX - 1, y: tab.midY), tab: tab, details: popup), "pointer on capsule keeps details open")
        check(EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: popup.midX, y: popup.midY), tab: tab, details: popup), "pointer over details keeps them open")
        check(EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: (popup.maxX + tab.minX) / 2, y: tab.midY), tab: tab, details: popup), "crossing the window gap keeps details open")
        check(!EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: tab.midX, y: popup.maxY - 8), tab: tab, details: popup), "empty bounding-box corner does not hold details open")
        check(!EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: right.minX + 3, y: right.midY), tab: tab, details: nil), "invisible old orb does not intercept hovering")
        check(!EdgeDockGeometry.pointerIsInsideSidebar(CGPoint(x: 960, y: 500), tab: tab, details: popup), "leaving capsule and details allows dismissal")
        check(EdgeDockGeometry.nearestEdge(of: CGRect(x: 300, y: 400, width: 164, height: 176), in: visible) == .left, "off-edge position selects left dock")
        check(EdgeDockGeometry.nearestEdge(of: CGRect(x: 1200, y: 400, width: 164, height: 176), in: visible) == .right, "off-edge position selects right dock")
        let leftDisplay = CGRect(x: -2560, y: -100, width: 2560, height: 1400)
        let multi = EdgeDockGeometry.expandedFrame(edge: .left, visible: leftDisplay, size: size, centerY: -80)
        let multiTab = EdgeDockGeometry.tabFrame(edge: .left, visible: leftDisplay, expanded: multi, scale: 1.35)
        check(leftDisplay.contains(multi), "negative-origin screen clamps expanded window")
        check(leftDisplay.contains(multiTab), "negative-origin screen clamps tab")
        check(multiTab.minX == -2560, "left tab belongs to correct display")
        let multiPopup = EdgeDockGeometry.detailsFrame(edge: .left, visible: leftDisplay, tab: multiTab)
        check(leftDisplay.contains(multiPopup) && multiPopup.minX > multiTab.maxX, "left dock opens details inward on a negative-origin display")
        let top = EdgeDockGeometry.expandedFrame(edge: .right, visible: visible, size: size, centerY: 10000)
        check(top.maxY == visible.maxY, "top clamp")
        let bottom = EdgeDockGeometry.expandedFrame(edge: .left, visible: visible, size: size, centerY: -10000)
        check(bottom.minY == visible.minY, "bottom clamp")
        let topTab = EdgeDockGeometry.tabFrame(edge: .right, visible: visible, expanded: top, scale: 1)
        let bottomTab = EdgeDockGeometry.tabFrame(edge: .left, visible: visible, expanded: bottom, scale: 1)
        check(visible.contains(EdgeDockGeometry.detailsFrame(edge: .right, visible: visible, tab: topTab)), "popup near screen top stays visible")
        check(visible.contains(EdgeDockGeometry.detailsFrame(edge: .left, visible: visible, tab: bottomTab)), "popup near screen bottom stays visible")
        for work in [visible, leftDisplay] {
            for edge in [DockEdge.left, .right] {
                for y in [work.minY - 100, work.minY + 32, work.midY, work.maxY - 32, work.maxY + 100] {
                    let anchor = EdgeDockGeometry.expandedFrame(edge: edge, visible: work, size: size, centerY: y, compact: true)
                    let capsule = EdgeDockGeometry.tabFrame(edge: edge, visible: work, expanded: anchor, scale: 1)
                    let expectedY = min(max(y, work.minY + 32), work.maxY - 32)
                    check(work.contains(capsule) && abs(capsule.midY - expectedY) <= 0.5, "capsule can dock near top/bottom independently of hidden orb size")
                    check(EdgeDockGeometry.edge(of: anchor, in: work) == edge, "partially offscreen hidden anchor retains the correct dock")
                }
            }
        }
        for scale in [0.8, 1.0, 1.35] {
            let expanded = EdgeDockGeometry.expandedFrame(edge: .right, visible: visible, size: CGSize(width: 164 * scale, height: 176 * scale), centerY: right.midY)
            let strip = EdgeDockGeometry.tabFrame(edge: .right, visible: visible, expanded: expanded, scale: scale)
            check(strip.size == EdgeDockGeometry.tabSize, "compact row stays small at orb scale \(scale)")
            check(visible.contains(strip) && visible.contains(expanded), "scale \(scale) remains on screen")
        }
        check(EdgeDockProtection(showingDetails: true).holdsExpanded, "details remain usable")
        check(EdgeDockProtection(showingSettings: true).holdsExpanded, "settings preview remains expanded")
        check(EdgeDockProtection(trackingMenu: true).holdsExpanded, "context menu remains usable")
        check(EdgeDockProtection(dragging: true).holdsExpanded, "drag cannot collapse mid-gesture")
        for work in [visible, leftDisplay] {
            for edge in [DockEdge.left, .right] {
                for y in [work.minY + 32, work.midY, work.maxY - 32] {
                    let expanded = EdgeDockGeometry.expandedFrame(edge: edge, visible: work, size: size, centerY: y)
                    let tab = EdgeDockGeometry.tabFrame(edge: edge, visible: work, expanded: expanded, scale: 1)
                    let popup = EdgeDockGeometry.detailsFrame(edge: edge, visible: work, tab: tab)
                    let hud = QuotaHUDGeometry.frame(visible: work, anchor: tab, obstacle: popup)
                    check(work.contains(hud), "HUD stays on screen at either edge and display origin")
                    check(!hud.intersects(tab) && !hud.intersects(popup), "HUD avoids capsule and open quota details")
                }
            }
        }
        check(visible.contains(QuotaHUDGeometry.frame(visible: visible, anchor: nil)), "hidden sidebar has an on-screen HUD fallback")
        print("PASS: \(count) side-dock geometry and interaction checks")
    }
}
