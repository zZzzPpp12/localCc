import SwiftUI
import AppKit

@MainActor
final class ApprovalPanelState: ObservableObject {
    @Published var request: OrbitApprovalRequest?
    @Published var count = 0
    @Published var isPreview = false
}

struct ApprovalBadgeView: View {
    @ObservedObject var state: ApprovalPanelState
    var expand: () -> Void
    var body: some View {
        Button(action: expand) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 12))
                Text("待授权 \(state.count)").font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }.foregroundStyle(Color.orange).frame(width: 132, height: 30)
                .background(Color(white: 0.035), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.5), lineWidth: 0.7))
        }.buttonStyle(.plain).padding(2).frame(width: 136, height: 34)
        .accessibilityLabel("Codex 有 \(state.count) 项操作等待授权，点击查看内容")
    }
}

struct ApprovalCardView: View {
    @ObservedObject var state: ApprovalPanelState
    var decide: (UUID, OrbitApprovalDecision) -> Void
    var collapse: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(Color.orange)
                Text(state.isPreview ? "Codex 授权 · 样式预览" : "Codex 等待你授权")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(state.count) 项").font(.system(size: 10)).foregroundStyle(.secondary)
                Button(action: collapse) { Image(systemName: "minus").frame(width: 18, height: 18) }
                    .buttonStyle(.plain).accessibilityLabel("收起授权详情，继续等待")
            }
            if let request = state.request {
                HStack(spacing: 5) {
                    Text(request.title).font(.system(size: 11, weight: .medium))
                    Text("· \(request.toolName)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(request.deadline.timeIntervalSince(context.date))))s")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let reason = request.reason, !reason.isEmpty {
                            Text(reason).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                        }
                        Text("目录：\(request.cwd)").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("会话：\(request.sessionID)\(request.turnID.map { " · " + $0 } ?? "")")
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        Text(request.inputJSON).font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                }.background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 7) {
                    Button("回 Codex 处理") { decide(request.id, .original) }.buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button("拒绝") { decide(request.id, .deny) }.buttonStyle(.bordered)
                    Button(state.isPreview ? "演示允许" : "允许一次") { decide(request.id, .allow) }
                        .buttonStyle(.borderedProminent).tint(.orange)
                }.controlSize(.small)
            }
        }.padding(14).frame(width: 324, height: 272)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.7))
        .padding(4).frame(width: 332, height: 280)
    }
}

@MainActor
final class ApprovalPanelController {
    private let bridge: ApprovalBridge
    private let onExpand: () -> Void
    private let state = ApprovalPanelState()
    private var badge: FloatingPanel?
    private var card: DetailsPanel?
    private var expanded = false
    private var visible = CGRect.zero
    private var anchor: CGRect?
    var obstacle: CGRect? { card?.isVisible == true ? card?.frame : (badge?.isVisible == true ? badge?.frame : nil) }
    var cardContent: NSView? { card?.contentView }
    var badgeContent: NSView? { badge?.contentView }
    var ownsKeyboardFocus: Bool { card?.isKeyWindow == true }
    var isExpanded: Bool { expanded }
    var badgeVisible: Bool { badge?.isVisible == true }
    var cardVisible: Bool { card?.isVisible == true }

    init(bridge: ApprovalBridge, onExpand: @escaping () -> Void = {}) { self.bridge = bridge; self.onExpand = onExpand }

    func update(visible: CGRect, anchor: CGRect?, suspended: Bool = false) {
        self.visible = visible; self.anchor = anchor
        if state.isPreview && (!bridge.requests.isEmpty || (state.request?.deadline ?? .distantPast) < Date()) {
            state.isPreview = false
        }
        if !state.isPreview {
            if state.request?.id != bridge.requests.first?.id { expanded = false; card?.orderOut(nil) }
            state.request = bridge.requests.first
            state.count = bridge.requests.count
        }
        guard state.request != nil, !suspended else {
            badge?.orderOut(nil); card?.orderOut(nil); expanded = false; return
        }
        if badge == nil {
            let panel = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel, title: "Codex Orbit 待授权")
            let hosting = NSHostingView(rootView: ApprovalBadgeView(state: state, expand: { [weak self] in self?.setExpanded(true) }))
            hosting.sizingOptions = []; panel.contentView = hosting; badge = panel
        }
        let badgeFrame = frame(size: CGSize(width: 136, height: 34))
        if badge?.frame != badgeFrame { badge?.setFrame(badgeFrame, display: true) }
        badge?.orderFrontRegardless()
        if expanded { showCard() }
    }

    func setExpanded(_ value: Bool) {
        expanded = value
        if value { onExpand(); showCard() } else { card?.orderOut(nil) }
    }

    private func showCard() {
        guard state.request != nil else { return }
        if card == nil {
            let panel = DetailsPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel, title: "Codex Orbit 授权详情")
            let hosting = NSHostingView(rootView: ApprovalCardView(state: state,
                decide: { [weak self] id, decision in self?.decide(id, decision) }, collapse: { [weak self] in self?.setExpanded(false) }))
            hosting.sizingOptions = []; panel.contentView = hosting; card = panel
        }
        let cardFrame = frame(size: CGSize(width: 332, height: 280))
        if card?.frame != cardFrame { card?.setFrame(cardFrame, display: true) }
        // Expanding is a deliberate click. The card supports scrolling and copying the complete input.
        card?.orderFrontRegardless()
    }

    func decide(_ id: UUID, _ decision: OrbitApprovalDecision) {
        guard let request = state.request, request.id == id else { return }
        if state.isPreview { state.isPreview = false; state.request = nil; state.count = 0 }
        else { bridge.decide(request, decision) }
        expanded = false; card?.orderOut(nil)
        update(visible: visible, anchor: anchor)
    }

    private func frame(size: CGSize) -> CGRect {
        let source = anchor ?? CGRect(x: visible.maxX - 116, y: visible.maxY - 100, width: 108, height: 56)
        let left = source.midX < visible.midX
        if size.width == 136 {
            let x = left ? source.minX : source.maxX - size.width
            let y = source.minY - size.height - 2 >= visible.minY + 4 ? source.minY - size.height - 2 : source.maxY + 2
            return CGRect(x: min(max(x, visible.minX + 4), visible.maxX - size.width - 4).rounded(),
                          y: min(max(y, visible.minY + 4), visible.maxY - size.height - 4).rounded(), width: size.width, height: size.height)
        }
        let x = left ? source.maxX + 2 : source.minX - size.width - 2
        return CGRect(x: min(max(x, visible.minX + 4), visible.maxX - size.width - 4).rounded(),
                      y: min(max(source.midY - size.height / 2, visible.minY + 4), visible.maxY - size.height - 4).rounded(),
                      width: size.width, height: size.height)
    }

    private func configure(_ panel: NSPanel, title: String) {
        panel.title = title; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false; panel.hasShadow = false
    }

    func preview(visible: CGRect, anchor: CGRect?) {
        let sample = Data("{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"样式预览\",\"cwd\":\"/示例项目\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"swift build\",\"description\":\"示例：构建当前项目，预览按钮不会执行命令。\"}}".utf8)
        state.request = try? OrbitApprovalRequest.fromHook(sample); state.count = 1; state.isPreview = true
        onExpand()
        expanded = true; update(visible: visible, anchor: anchor)
    }
}
