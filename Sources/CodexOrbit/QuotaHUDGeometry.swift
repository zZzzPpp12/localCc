import Foundation
import CoreGraphics

enum QuotaHUDGeometry {
    static let size = CGSize(width: 216, height: 38)

    static func frame(visible: CGRect, anchor: CGRect?, obstacle: CGRect? = nil) -> CGRect {
        let inset: CGFloat = 8
        let anchor = anchor ?? CGRect(x: visible.maxX - 116, y: visible.maxY - 70, width: 108, height: 56)
        // Keep short-lived alerts in the edge strip above the capsule / hover card.
        let left = anchor.midX < visible.midX
        let desiredX = left ? anchor.minX : anchor.maxX - size.width
        let x = min(max(desiredX, visible.minX + inset), visible.maxX - size.width - inset)
        let top = max(anchor.maxY, obstacle?.maxY ?? anchor.maxY)
        let bottom = min(anchor.minY, obstacle?.minY ?? anchor.minY)
        let above = top + 2
        let below = bottom - 2 - size.height
        let desiredY = above + size.height <= visible.maxY - inset ? above : below
        let y = min(max(desiredY, visible.minY + inset), visible.maxY - size.height - inset)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}
