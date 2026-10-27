import SwiftUI

struct SideQuotaDetailsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var activity: HarnessActivityStore
    @ObservedObject var dashboard: DashboardStore
    var close: () -> Void
    var openSettings: () -> Void
    var openCodex: () -> Void
    var refresh: () -> Void
    var hoverChanged: (Bool) -> Void
    @State private var range: DashboardRange = .week
    @State private var showUsed = false
    @State private var hoveredDay: DashboardDay?

    private var trend: DashboardTrend {
        DashboardTrend(buckets: dashboard.tokens?.dailyUsageBuckets, range: range, now: store.now)
    }
    private var mint: Color { OrbitPalette.mint }
    private var chartValue: Int64? {
        if let hoveredDay { return hoveredDay.tokens }
        return trend.total
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    quotaSection
                    separator
                    tokenSection
                    separator
                    sessionsSection
                }
            }
            separator
            footer
        }
        .padding(14).frame(width: EdgeDockGeometry.detailsSize.width - 12, height: EdgeDockGeometry.detailsSize.height - 12)
        .background {
            RoundedRectangle(cornerRadius: 21, style: .continuous).fill(.regularMaterial)
                .overlay(LinearGradient(colors: [mint.opacity(0.10), OrbitPalette.lilac.opacity(0.035), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous)))
        }
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).strokeBorder(mint.opacity(0.20), lineWidth: 0.7))
        .padding(6).frame(width: EdgeDockGeometry.detailsSize.width, height: EdgeDockGeometry.detailsSize.height)
        .onHover(perform: hoverChanged)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codex 额度、Token 趋势与本机最近会话")
    }

    private var header: some View {
        HStack(spacing: 7) {
            CodexThinkingIcon(image: ProviderArtwork.codex, working: activity.phase == .working, animate: activity.animationActive)
                .frame(width: 24, height: 24)
            Text("Codex").font(.system(size: 14, weight: .semibold))
            if let plan = store.snapshot?.account.planName {
                Text(plan).font(.system(size: 9, weight: .medium)).foregroundStyle(mint)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(mint.opacity(0.10), in: Capsule())
            }
            Spacer(minLength: 3)
            HStack(spacing: 1) {
                modeButton("剩余", used: false)
                modeButton("已用", used: true)
            }.padding(2).background(Color.primary.opacity(0.055), in: Capsule())
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10)).frame(width: 20, height: 22)
            }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(store.isRefreshing || dashboard.isRefreshing).help("刷新额度与统计")
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 22)
            }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("收起悬停面板")
        }.frame(height: 28)
    }
    private func modeButton(_ title: String, used: Bool) -> some View {
        Button { showUsed = used } label: {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(showUsed == used ? mint : .secondary)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(showUsed == used ? mint.opacity(0.12) : Color.clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel("显示\(title)额度").accessibilityValue(showUsed == used ? "已选择" : "未选择")
    }
    private var quotaSection: some View {
        VStack(spacing: 7) {
            quotaRow(store.window(.short), label: "\(store.window(.short)?.shortTitle ?? "5h") 额度", period: .short)
            quotaRow(store.window(.weekly), label: "\(store.window(.weekly)?.shortTitle ?? "每周")额度", period: .weekly)
            if let buckets = store.snapshot?.limits.buckets {
                ForEach(buckets.filter { $0.id != store.bucket?.id && $0.window(.weekly) != nil }.prefix(2)) { bucket in
                    quotaRow(bucket.window(.weekly), label: "每周 · \(bucket.displayName)", period: .weekly)
                }
            }
        }.padding(.top, 13).padding(.bottom, 12)
        .opacity(store.isStale ? 0.55 : 1)
    }
    private func quotaRow(_ window: QuotaWindow?, label: String, period: QuotaPeriod) -> some View {
        let tint = OrbitPalette.period(period)
        let remaining = window?.remaining
        let value = remaining.map { showUsed ? 100 - $0 : $0 }
        let color = remaining.map { $0 <= 10 ? Color.red : tint } ?? Color.secondary
        return HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.10))
                    if let value { Capsule().fill(color).frame(width: geometry.size.width * value / 100) }
                }
            }.frame(width: 38, height: 3).accessibilityHidden(true)
            Text(value.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
                .frame(width: 42, alignment: .trailing)
            Text(DashboardFormat.reset(window, now: store.now)).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
                .help(window?.resetDescription(at: store.now) ?? "重置时间未知")
        }.frame(height: 23)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label)，\(showUsed ? "已用" : "剩余")\(value.map { "\(Int($0.rounded()))%" } ?? "未知")，\(window?.resetDescription(at: store.now) ?? "重置时间未知")")
    }

    private var tokenSection: some View {
        VStack(spacing: 7) {
            HStack(spacing: 5) {
                Text("Token 消耗").font(.system(size: 11, weight: .semibold))
                Spacer()
                ForEach(DashboardRange.allCases) { item in
                    Button { range = item; hoveredDay = nil } label: {
                        Text(item.title).font(.system(size: 9, weight: .medium)).foregroundStyle(range == item ? mint : .secondary)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(range == item ? mint.opacity(0.12) : Color.clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("查看\(item.title)Token统计")
                }
                Text(DashboardFormat.tokens(chartValue) + (chartValue == nil ? "" : " tok"))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit().frame(minWidth: 58, alignment: .trailing)
            }
            tokenChart
            HStack {
                Text(hoveredDay?.id ?? (trend.days.first?.id.suffix(5).description ?? ""))
                Spacer()
                Text(hoveredDay == nil ? "\(trend.knownDays)/\(range.rawValue) 天有记录 · 服务端日期" : "按日汇总")
            }.font(.system(size: 8)).foregroundStyle(.tertiary)
        }.padding(.vertical, 11)
        .help(tokenSummaryHelp)
    }
    private var tokenChart: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack {
                    Rectangle().fill(Color.primary.opacity(0.035)).frame(height: 0.5)
                    Spacer()
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5)
                }
                if trend.knownDays == 0 {
                    HStack(spacing: 6) {
                        if dashboard.isRefreshing { ProgressView().controlSize(.mini) }
                        Text(dashboard.isRefreshing ? "正在读取 Token 统计" : (dashboard.tokenError ?? "所选日期暂无统计"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxHeight: .infinity)
                } else {
                    HStack(alignment: .bottom, spacing: range == .month ? 3 : 6) {
                        ForEach(trend.days) { day in
                            VStack {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(day.tokens == nil ? Color.primary.opacity(0.08) : mint.opacity(hoveredDay?.id == day.id ? 1 : 0.72))
                                    .frame(width: min(12, max(3, geometry.size.width / CGFloat(range.rawValue) - 4)),
                                           height: day.tokens.map { max(2, geometry.size.height * CGFloat($0) / CGFloat(trend.peak)) } ?? 2)
                            }.frame(maxWidth: .infinity)
                                .contentShape(Rectangle()).onHover { hoveredDay = $0 ? day : nil }
                                .help("\(day.id)：\(day.tokens.map { DashboardFormat.tokens($0) + " tok" } ?? "未返回数据")")
                                .accessibilityLabel("\(day.id)，\(day.tokens.map { DashboardFormat.tokens($0) + " Token" } ?? "未返回数据")")
                        }
                    }
                }
            }
        }.frame(height: 48)
    }
    private var tokenSummaryHelp: String {
        guard let summary = dashboard.tokens?.summary else { return "使用 Codex 官方每日 Token 汇总；缺失日期不计为零。" }
        return "累计 \(DashboardFormat.tokens(summary.lifetimeTokens)) tok · 单日峰值 \(DashboardFormat.tokens(summary.peakDailyTokens)) tok · 连续 \(summary.currentStreakDays.map(String.init) ?? "—") 天。趋势合计仅包含已返回的日期；会话列表是本机累计值。"
    }

    private var sessionsSection: some View {
        VStack(spacing: 7) {
            HStack {
                Text("最近会话").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("本机 · 最近更新").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if dashboard.sessions.isEmpty {
                Text(dashboard.isRefreshing ? "正在读取本机会话…" : (dashboard.sessionError ?? "暂无本机会话"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ForEach(dashboard.sessions.prefix(4)) { session in
                    sessionRow(session)
                }
            }
        }.padding(.top, 11).padding(.bottom, 10)
    }
    private func sessionRow(_ session: DashboardSession) -> some View {
        HStack(spacing: 6) {
            if let image = ProviderArtwork.codex {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().frame(width: 12, height: 12).foregroundStyle(mint.opacity(0.8))
            }
            Text("\(Text(session.title).foregroundColor(.primary))\(Text(" · " + session.project).foregroundColor(.secondary))")
                .font(.system(size: 10)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Text(session.localTokens.map { DashboardFormat.tokens($0) + " tok" } ?? "—")
                .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }.frame(height: 20)
        .help("\(session.title)\n\(session.cwd)\n\(DashboardFormat.relative(session.updatedAt, now: store.now))更新\(session.model.map { " · " + $0 } ?? "")\nToken 为本机会话累计元数据；未记录时显示 —。")
        .accessibilityElement(children: .combine)
    }
    private var separator: some View { Rectangle().fill(Color.primary.opacity(0.065)).frame(height: 0.5) }
    private var footer: some View {
        HStack(spacing: 5) {
            Circle().fill(activity.phase == .working ? mint : Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
            Text(activity.phase == .unknown ? store.statusText : activity.phase.description).font(.system(size: 9)).foregroundStyle(.secondary)
            if (dashboard.tokenError != nil || dashboard.sessionError != nil) && (dashboard.tokens != nil || !dashboard.sessions.isEmpty) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).foregroundStyle(.orange)
                    .help("部分统计未能更新，已保留最近读数。可点击右上角刷新重试。")
                    .accessibilityLabel("部分统计待更新")
            }
            Spacer()
            if dashboard.isRefreshing { ProgressView().controlSize(.mini) }
            Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 22, height: 22) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("打开设置")
            Button(action: openCodex) { Image(systemName: "arrow.up.right.square").font(.system(size: 11)).frame(width: 20, height: 22) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("打开 Codex")
        }.padding(.top, 7).frame(height: 29)
    }
}
