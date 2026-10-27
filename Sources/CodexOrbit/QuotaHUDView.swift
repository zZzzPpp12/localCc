import SwiftUI

@MainActor
final class QuotaHUDPresentation: ObservableObject {
    @Published var alert = QuotaHUDAlert.preview(.low)
    @Published var now = Date()
    @Published var isVisible = false
    @Published var isCapturing = false
}

struct QuotaHUDView: View {
    @ObservedObject var presentation: QuotaHUDPresentation
    var dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var alert: QuotaHUDAlert { presentation.alert }
    private var tint: Color {
        alert.level == .exhausted ? Color(red: 1, green: 0.31, blue: 0.29) : Color(red: 1, green: 0.66, blue: 0.36)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reduceMotion || !presentation.isVisible || presentation.isCapturing)) { timeline in
            let glow = reduceMotion ? 0.65 : 0.58 + 0.22 * cos(timeline.date.timeIntervalSinceReferenceDate * .pi / 1.5)
            HStack(spacing: 6) {
                if let image = ProviderArtwork.codex {
                    Image(nsImage: image).resizable().renderingMode(.template).scaledToFit()
                        .foregroundStyle(tint).frame(width: 18, height: 18)
                }
                Text(alert.window.shortTitle).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                Text(alert.level == .exhausted ? "已耗尽" : "快耗尽")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(alert.remainingText).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().foregroundStyle(tint)
                if alert.isPreview { Text("预览").font(.system(size: 8)).foregroundStyle(.white.opacity(0.45)) }
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5)).frame(width: 16, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("关闭额度 HUD 提醒")
            }
            .padding(.horizontal, 10).frame(width: QuotaHUDGeometry.size.width - 4, height: QuotaHUDGeometry.size.height - 4)
            .background(Color(white: 0.025).opacity(0.98), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(glow * 0.75), lineWidth: 0.8))
            .padding(2).frame(width: QuotaHUDGeometry.size.width, height: QuotaHUDGeometry.size.height)
        }
        .help("\(alert.bucketName.map { $0 + " · " } ?? "")\(alert.window.resetDescription(at: presentation.now))")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(alert.isPreview ? "样式预览，" : "")Codex \(alert.periodTitle)，\(alert.level.title)，剩余 \(alert.remainingText)")
    }
}
