import SwiftUI
import AppKit

enum OrbitPalette {
    static let mint = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.33, green: 0.89, blue: 0.72, alpha: 1) : NSColor(srgbRed: 0.06, green: 0.55, blue: 0.43, alpha: 1) })
    static let lilac = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.76, green: 0.65, blue: 0.98, alpha: 1) : NSColor(srgbRed: 0.51, green: 0.36, blue: 0.73, alpha: 1) })
    static let amber = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.76, blue: 0.34, alpha: 1) : NSColor(srgbRed: 0.69, green: 0.39, blue: 0.02, alpha: 1) })
    static func period(_ period: QuotaPeriod) -> Color { period == .short ? mint : lilac }
    static func quota(_ window: QuotaWindow?, period: QuotaPeriod) -> Color {
        guard let remaining = window?.remaining else { return .secondary }
        if remaining <= 5 { return .red }
        if remaining <= 20 { return amber }
        return self.period(period)
    }
}

struct QuotaArc: Shape {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius,
                    startAngle: .degrees(135), endAngle: .degrees(135 + 270 * max(0, min(1, progress))), clockwise: false)
        return path
    }
}

struct OrbView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: OrbitPreferences
    var openDetails: () -> Void
    var dragChanged: () -> Void
    var dragEnded: () -> Void
    var contextMenu: () -> Void
    var hoverChanged: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Button(action: openDetails) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(LinearGradient(colors: [OrbitPalette.mint.opacity(scheme == .dark ? 0.13 : 0.07), Color.clear, OrbitPalette.lilac.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
                    ring(.short, size: 103, width: 4.5)
                    ring(.weekly, size: 79, width: 3.5)
                    VStack(spacing: 1) {
                        Text(store.selectedWindow?.percentText ?? "—")
                            .font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                            .foregroundStyle((store.selectedWindow?.remaining ?? 100) <= 20 ? OrbitPalette.quota(store.selectedWindow, period: preferences.selectedPeriod) : .primary)
                        Text("\(store.selectedWindow?.shortTitle ?? preferences.selectedPeriod.fallbackTitle) 剩余")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .offset(y: -1)
                    statusMark.offset(y: 39)
                }
                .frame(width: 116, height: 116)
                .shadow(color: OrbitPalette.mint.opacity(hovering ? 0.20 : 0.08), radius: hovering ? 16 : 9, y: 3)
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.25 : 0.10), radius: 8, y: 5)
                .scaleEffect(hovering ? 1.025 : 1)
                .opacity(store.isStale ? 0.70 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Codex 额度，\(store.selectedWindow?.title ?? preferences.selectedPeriod.fallbackTitle)剩余 \(store.selectedWindow?.percentText ?? "未知")。点击展开详情")
            .help(orbHelp)
            HStack(spacing: 5) {
                periodLabel(.short)
                periodLabel(.weekly)
            }
        }
        .padding(.top, 16).padding(.horizontal, 10).padding(.bottom, 13)
        .frame(width: 164, height: 176)
        .onHover { hovering = $0; hoverChanged($0) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: hovering)
        .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { _ in dragChanged() }.onEnded { _ in dragEnded() })
        .contextMenu {
            Button("展开详情", action: openDetails)
            Button("立即刷新") { Task { await store.refresh() } }.disabled(store.isRefreshing)
            Divider()
            Button("隐藏悬浮球") { preferences.showOrb = false }
            Button("设置…", action: contextMenu)
        }
    }

    private func ring(_ period: QuotaPeriod, size: CGFloat, width: CGFloat) -> some View {
        let window = store.window(period)
        let selected = preferences.selectedPeriod == period
        return ZStack {
            QuotaArc(progress: 1).stroke(Color.primary.opacity(0.065), style: StrokeStyle(lineWidth: width, lineCap: .round))
            if window?.remaining != nil {
                QuotaArc(progress: window!.fraction)
                    .stroke(OrbitPalette.period(period).opacity(selected ? 1 : 0.73), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: window?.remaining)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var statusMark: some View {
        if store.isRefreshing && store.snapshot == nil {
            ProgressView().controlSize(.mini).scaleEffect(0.6).frame(height: 8)
        } else if store.lastError != nil || store.isStale {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(OrbitPalette.amber)
        } else if store.blocked {
            Image(systemName: "pause.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
        } else if QuotaPeriod.allCases.contains(where: { (store.window($0)?.remaining ?? 100) <= 20 }) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(OrbitPalette.amber)
        } else {
            Capsule().fill(OrbitPalette.period(preferences.selectedPeriod).opacity(0.6)).frame(width: 12, height: 3)
        }
    }

    private func periodLabel(_ period: QuotaPeriod) -> some View {
        let selected = preferences.selectedPeriod == period
        let title = store.window(period)?.shortTitle ?? period.fallbackTitle
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { preferences.selectedPeriod = period }
        } label: {
            HStack(spacing: 3) {
                if (store.window(period)?.remaining ?? 100) <= 20 {
                    Image(systemName: "exclamationmark").font(.system(size: 8, weight: .bold)).foregroundStyle(OrbitPalette.quota(store.window(period), period: period)).frame(width: 4)
                } else {
                    Circle().fill(OrbitPalette.period(period)).frame(width: 4, height: 4)
                }
                Text(period == .short ? "外 \(title)" : "内 \(title)")
                    .font(.system(size: 10, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.primary : .secondary)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(OrbitPalette.period(period).opacity(selected ? 0.35 : 0.05), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(period == .short ? "外环" : "内环")，\(store.window(period)?.title ?? period.fallbackTitle)，剩余 \(store.window(period)?.percentText ?? "未知")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help("点击在球心查看\(store.window(period)?.title ?? period.fallbackTitle)")
    }

    private var orbHelp: String {
        QuotaPeriod.allCases.map { period in
            guard let window = store.window(period) else { return "\(period.fallbackTitle)：未知" }
            return "\(window.title)：剩余 \(window.percentText)，\(window.resetDescription(at: store.now))"
        }.joined(separator: "\n") + "\n拖动移动 · 点击展开 · 右键菜单"
    }
}

struct EdgeTabView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var activity: HarnessActivityStore
    @ObservedObject var state: EdgeDockState
    var hoverChanged: (Bool) -> Void
    var openDetails: () -> Void
    var openSettings: () -> Void

    var body: some View {
        Button(action: openDetails) {
            EdgeTabReadout(window: store.window(.short), stale: store.isStale,
                           warning: store.lastError != nil || store.blocked,
                           activityPhase: activity.phase, animateActivity: activity.animationActive)
        }
        .buttonStyle(.plain)
        .onHover(perform: hoverChanged)
        .accessibilityLabel("Codex Orbit 侧边标签，\(summary)，\(store.statusText)，\(activity.phase.description)。移入指针在旁边查看 5h 和每周额度详情")
        .contextMenu {
            Button("额度详情", action: openDetails)
            Button("设置…", action: openSettings)
        }
    }

    private var summary: String {
        QuotaPeriod.allCases.map { period in
            "\(store.window(period)?.title ?? period.fallbackTitle)剩余 \(store.window(period)?.percentText ?? "未知")"
        }.joined(separator: "，")
    }
}

enum ProviderArtwork {
    static let codex: NSImage? = Bundle.main.url(forResource: "codex", withExtension: "png", subdirectory: "ProviderAssets").flatMap { NSImage(contentsOf: $0) }
}

/// A reference-style provider row; more providers would stack vertically.
struct EdgeTabReadout: View {
    let window: QuotaWindow?
    var stale = false
    var warning = false
    var codexLogo: NSImage? = ProviderArtwork.codex
    var activityPhase: HarnessPhase = .idle
    var animateActivity = false
    var fixedThinkingPhase: Double? = nil
    var reduceMotionOverride: Bool? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var quotaColor: Color {
        guard let remaining = window?.remaining, !stale else { return .white.opacity(0.40) }
        if remaining < 30 { return Color(red: 1, green: 0.43, blue: 0.47) }
        if remaining < 60 { return Color(red: 1, green: 0.81, blue: 0.38) }
        return Color(red: 0.35, green: 0.84, blue: 0.66)
    }

    var body: some View {
        HStack(spacing: 19) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.09), lineWidth: 1.8)
                if window?.remaining != nil {
                    Circle().trim(from: 0, to: window!.fraction)
                        .stroke(quotaColor, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                CodexThinkingIcon(image: codexLogo, working: activityPhase == .working,
                                  animate: animateActivity, fixedPhase: fixedThinkingPhase, reduceMotionOverride: reduceMotionOverride)
            }
            .frame(width: 36, height: 36)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: window?.remaining)
            .accessibilityHidden(true)
            Text(window?.percentText ?? "—")
                .font(.system(size: 16, weight: .regular, design: .rounded)).monospacedDigit()
                .foregroundStyle(quotaColor).lineLimit(1).minimumScaleFactor(0.82)
                .frame(width: 38, alignment: .leading)
        }
        .opacity(stale ? 0.55 : 1)
        .frame(width: EdgeDockGeometry.tabSize.width, height: EdgeDockGeometry.tabSize.height)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(warning ? Color.orange.opacity(0.45) : Color.white.opacity(0.05), lineWidth: 0.6)
        }
    }
}

struct DetailsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: OrbitPreferences
    var openSettings: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(OrbitPalette.mint.opacity(0.12)).frame(width: 36, height: 36)
                    Image(systemName: "circle.hexagongrid").font(.system(size: 18, weight: .medium)).foregroundStyle(OrbitPalette.mint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Orbit").font(.system(size: 16, weight: .semibold))
                    Text("让每一份额度，心中有数").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(store.snapshot?.account.planName ?? "CODEX").font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(OrbitPalette.mint.opacity(0.10), in: Capsule())
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("收起详情").accessibilityLabel("收起详情")
            }
            HStack(spacing: 5) {
                Circle().fill(store.lastError == nil && !store.isStale ? OrbitPalette.mint : OrbitPalette.amber).frame(width: 5, height: 5)
                Text(store.statusText)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.mini) }
                else { Text(store.updateDescription) }
            }.font(.system(size: 10)).foregroundStyle(.secondary)

            if let error = store.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                        if store.needsLogin {
                            Button(store.isLoggingIn ? "等待登录…" : "使用 ChatGPT 登录") { Task { await store.login() } }.disabled(store.isLoggingIn || store.isRefreshing)
                        }
                        if store.cliPath == nil && CLILocator.find(custom: preferences.customCLI) == nil {
                            Button("选择 Codex 路径…", action: openSettings)
                        }
                    }
                }.font(.system(size: 11)).foregroundStyle(OrbitPalette.amber).padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrbitPalette.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            if store.isLoggingIn {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("请在浏览器完成登录").font(.system(size: 11))
                    Spacer()
                    Button("取消") { Task { await store.cancelLogin() } }.font(.system(size: 11))
                }
            }
            if let buckets = store.snapshot?.limits.buckets, buckets.count > 1 {
                Picker("额度组", selection: $preferences.bucketID) {
                    ForEach(buckets) { bucket in Text(bucket.displayName).tag(bucket.id) }
                }.font(.system(size: 11))
            }

            VStack(spacing: 20) {
                quotaRow(.short)
                quotaRow(.weekly)
            }
            if store.blocked {
                Label("服务已标记套餐使用受限，请以 Codex 中的提示为准。", systemImage: "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(OrbitPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                Text("外环对应短周期，内环对应长周期。")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                Button { preferences.showOrb.toggle() } label: {
                    Label(preferences.showOrb ? "隐藏悬浮球" : "显示悬浮球", systemImage: preferences.showOrb ? "eye.slash" : "eye")
                }.buttonStyle(.plain).font(.system(size: 11))
                Spacer()
                Button(action: openSettings) { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
                Button { Task { await store.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(OrbitPalette.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(store.isRefreshing || store.isLoggingIn)
            }
        }
        .padding(22).frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6))
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex 额度详情")
    }

    private func quotaRow(_ period: QuotaPeriod) -> some View {
        let window = store.window(period)
        let tint = OrbitPalette.quota(window, period: period)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(OrbitPalette.period(period)).frame(width: 5, height: 5)
                        Text(window?.title ?? "\(period.fallbackTitle)额度").font(.system(size: 12, weight: .medium))
                    }
                    Text(period == .short ? "OUTER · 外环" : "INNER · 内环")
                        .font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window?.percentText ?? "—").font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.065))
                    if let remaining = window?.remaining {
                        Capsule().fill(tint).frame(width: proxy.size.width * remaining / 100)
                    }
                }
            }.frame(height: 5).accessibilityHidden(true)
            HStack {
                Text(window?.resetDescription(at: store.now) ?? "该额度窗口尚未返回")
                Spacer(minLength: 4)
                if let used = window?.usedPercent {
                    Text("已用 \(Int(max(0, min(100, used)).rounded()))%")
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            if let date = window?.resetDate {
                Text(date.formatted(.dateTime.month().day().hour().minute()) + " 重置")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .opacity(store.isStale ? 0.70 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct OrbitSettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var preferences: OrbitPreferences
    @ObservedObject var launchAtLogin: LaunchAtLogin
    var resetPosition: () -> Void
    var chooseCLI: () -> Void
    var openCodex: () -> Void
    var previewHUD: (QuotaHUDLevel) -> Void
    @ObservedObject var approvalBridge: ApprovalBridge
    @ObservedObject var activity: HarnessActivityStore
    @State private var previewThinking = false
    var previewApproval: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid").font(.system(size: 30)).foregroundStyle(OrbitPalette.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Orbit").font(.system(size: 20, weight: .semibold))
                    Text("薄荷双环 · v0.8.0").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }.padding(24)
            Form {
                Section("启动") {
                    Toggle("登录 Mac 后自动启动", isOn: Binding(get: { launchAtLogin.isRequested }, set: { launchAtLogin.setEnabled($0) }))
                    Text(launchAtLogin.description).font(.system(size: 11)).foregroundStyle(.secondary)
                    if launchAtLogin.requiresApproval || launchAtLogin.errorMessage != nil {
                        Button("打开系统登录项设置") { launchAtLogin.openSystemSettings() }
                    }
                }
                Section("悬浮球") {
                    Toggle("显示悬浮球", isOn: $preferences.showOrb)
                    Toggle("自动吸附屏幕侧边", isOn: $preferences.snapToEdge)
                    Toggle("靠边自动隐藏，指针移入展开", isOn: $preferences.autoHideAtEdge)
                    LabeledContent("大小") { Slider(value: $preferences.scale, in: 0.8...1.35).frame(width: 180); Text("\(Int(preferences.scale * 100))%").monospacedDigit().frame(width: 42) }
                    LabeledContent("不透明度") { Slider(value: $preferences.opacity, in: 0.45...1).frame(width: 180); Text("\(Int(preferences.opacity * 100))%").monospacedDigit().frame(width: 42) }
                    Picker("外观", selection: $preferences.appearance) {
                        Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }
                    Button("将悬浮球移回主屏幕", action: resetPosition)
                }
                Section("刷新与提醒") {
                    Picker("自动刷新", selection: $preferences.refreshInterval) {
                        Text("每 60 秒").tag(60.0); Text("每 90 秒").tag(90.0); Text("每 120 秒").tag(120.0)
                    }
                    Text("状态栏提示灯：≥60% 绿 · 30%–<60% 黄 · <30% 红")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Toggle("汽车 HUD 额度提醒", isOn: $preferences.hudAlerts)
                    Text("5h / 每周剩余 ≤10% 提醒快耗尽，0% 提醒已耗尽；每周期各一次。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("预览快耗尽 HUD") { previewHUD(.low) }
                        Button("预览已耗尽 HUD") { previewHUD(.exhausted) }
                    }
                    Toggle("每周额度 30% 系统通知", isOn: Binding(get: { preferences.notifications }, set: { enabled in Task { await store.setNotifications(enabled) } }))
                    Text(store.notificationMessage ?? "每周剩余 ≤30% 时通知，同一周只提醒一次，重启后也不重复。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("发送测试通知") { Task { await store.sendTestNotification() } }
                        .disabled(!preferences.notifications)
                }
                Section("Harness 工作状态") {
                    Toggle("工作时显示思考动画", isOn: $preferences.animateWhenWorking)
                    HStack {
                        CodexThinkingIcon(image: ProviderArtwork.codex, working: previewThinking || activity.phase == .working,
                                          animate: previewThinking || activity.animationActive)
                        Text(previewThinking ? "动画预览" : activity.phase.description).font(.system(size: 11))
                        Spacer()
                        Button("预览动画") {
                            previewThinking = true
                            Task { try? await Task.sleep(nanoseconds: 8_000_000_000); previewThinking = false }
                        }
                    }
                    Text(activity.hookStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("安装 / 更新工作状态 Hook") { activity.installHooks() }
                }
                Section("Codex 操作授权") {
                    Toggle("在额度胶囊显示待授权操作", isOn: $approvalBridge.enabled)
                    Text(approvalBridge.status).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("先显示小标签，点击后查看完整参数并允许一次或拒绝；120 秒未处理则回到 Codex 原有授权。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("安装 / 更新 Codex 授权 Hook") { approvalBridge.installHook() }
                        Button("预览授权卡片", action: previewApproval)
                    }
                }
                Section("Codex 连接") {
                    LabeledContent("账号") { Text(store.snapshot?.account.email ?? "尚未读取").textSelection(.enabled) }
                    LabeledContent("当前状态") { Text(store.statusText) }
                    HStack {
                        TextField("自动查找本机 Codex CLI", text: $preferences.customCLI)
                            .font(.system(size: 11, design: .monospaced))
                        Button("选择…", action: chooseCLI)
                    }
                    if let path = store.cliPath { Text(path).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
                    HStack {
                        Button("重新连接") { Task { await store.refresh(reconnect: true) } }.disabled(store.isRefreshing || store.isLoggingIn)
                        Button("打开 Codex", action: openCodex)
                        if store.needsLogin {
                            Button("ChatGPT 登录") { Task { await store.login() } }.disabled(store.isRefreshing || store.isLoggingIn)
                        }
                    }
                    Text("通过官方 App Server 读取套餐额度。凭证由 Codex 管理，本应用不保存密钥，也不发起模型任务。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped)
        }.frame(width: 510, height: 650)
    }
}
