import SwiftUI
import AppKit

struct CodexThinkingIcon: View {
    let image: NSImage?
    let working: Bool
    let animate: Bool
    var fixedPhase: Double? = nil
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let mint = Color(red: 0.20, green: 0.83, blue: 0.65)

    var body: some View {
        let reduced = reduceMotionOverride ?? reduceMotion
        return TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !animate || reduced || fixedPhase != nil)) { context in
            let phase = fixedPhase ?? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let pulse = (1 - cos(phase * 2 * .pi)) / 2
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(mint.opacity(working && !reduced ? 0.72 + 0.28 * pulse : 0.95))
                        .scaleEffect(working && !reduced ? 0.96 + 0.06 * pulse : 1)
                } else {
                    Text("C").font(.system(size: 18, weight: .medium)).foregroundStyle(mint)
                }
                if working {
                    if reduced {
                        Circle().fill(mint).frame(width: 3, height: 3).offset(y: 13)
                    } else {
                        ForEach(0..<3) { index in
                            Circle().fill(mint.opacity(1 - Double(index) * 0.28))
                                .frame(width: 2.3 - Double(index) * 0.3, height: 2.3 - Double(index) * 0.3)
                                .offset(y: -13)
                                .rotationEffect(.degrees(phase * 360 - Double(index) * 23))
                        }
                    }
                }
            }.frame(width: 28, height: 28)
        }
        .accessibilityHidden(true)
    }
}
