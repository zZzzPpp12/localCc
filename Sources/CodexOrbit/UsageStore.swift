import AppKit
import Combine
import UserNotifications

@MainActor
final class OrbitPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var selectedPeriod: QuotaPeriod { didSet { defaults.set(selectedPeriod.rawValue, forKey: "selectedPeriod") } }
    @Published var bucketID: String { didSet { defaults.set(bucketID, forKey: "bucketID") } }
    @Published var showOrb: Bool { didSet { defaults.set(showOrb, forKey: "showOrb") } }
    @Published var scale: Double { didSet { defaults.set(scale, forKey: "orbScale") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "orbOpacity") } }
    @Published var snapToEdge: Bool { didSet { defaults.set(snapToEdge, forKey: "snapToEdge") } }
    @Published var autoHideAtEdge: Bool { didSet { defaults.set(autoHideAtEdge, forKey: "autoHideAtEdge") } }
    @Published var animateWhenWorking: Bool { didSet { defaults.set(animateWhenWorking, forKey: "animateWhenWorking") } }
    @Published var hudAlerts: Bool { didSet { defaults.set(hudAlerts, forKey: "hudAlerts") } }
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "notifications") } }
    @Published var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var customCLI: String { didSet { defaults.set(customCLI, forKey: "customCLI") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["animateWhenWorking": true, "hudAlerts": true, "showOrb": true, "orbScale": 1.0, "orbOpacity": 1.0, "snapToEdge": true, "autoHideAtEdge": true, "refreshInterval": 90.0, "appearance": "system"])
        selectedPeriod = QuotaPeriod(rawValue: defaults.string(forKey: "selectedPeriod") ?? "short") ?? .short
        bucketID = defaults.string(forKey: "bucketID") ?? "codex"
        showOrb = defaults.bool(forKey: "showOrb")
        scale = min(1.35, max(0.8, defaults.double(forKey: "orbScale")))
        opacity = min(1, max(0.45, defaults.double(forKey: "orbOpacity")))
        snapToEdge = defaults.bool(forKey: "snapToEdge")
        autoHideAtEdge = defaults.bool(forKey: "autoHideAtEdge")
        animateWhenWorking = defaults.bool(forKey: "animateWhenWorking")
        hudAlerts = defaults.bool(forKey: "hudAlerts")
        notifications = defaults.bool(forKey: "notifications")
        refreshInterval = max(60, defaults.double(forKey: "refreshInterval"))
        customCLI = defaults.string(forKey: "customCLI") ?? ""
        appearance = defaults.string(forKey: "appearance") ?? "system"
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var needsLogin = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var now = Date()
    @Published private(set) var cliPath: String?
    @Published private(set) var notificationMessage: String?
    @Published private(set) var nextRefreshAt = Date()
    @Published private(set) var isSleeping = false
    let preferences: OrbitPreferences
    let client = AppServerClient()
    private var timer: Timer?
    private var failures = 0
    private let allowsNotifications: Bool
    private let defaults: UserDefaults
    private var weeklyAlerts: WeeklyAlertLedger
    private var isSendingWeeklyAlert = false
    private var loginID: String?
    private var loginTimeout: Task<Void, Never>?
    private var eventRefresh: Task<Void, Never>?
    private var accountRevision = 0

    init(preferences: OrbitPreferences, allowsNotifications: Bool = true, defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.allowsNotifications = allowsNotifications
        self.defaults = defaults
        weeklyAlerts = defaults.data(forKey: "weeklyAlertLedger").flatMap { try? JSONDecoder().decode(WeeklyAlertLedger.self, from: $0) } ?? WeeklyAlertLedger()
        client.onNotification = { [weak self] method, params in self?.notification(method: method, params: params) }
        client.onDisconnect = { [weak self] in
            guard let self else { return }
            if self.isLoggingIn {
                self.isLoggingIn = false
                self.loginID = nil
                self.loginTimeout?.cancel()
            }
            if !self.isSleeping {
                self.lastError = OrbitError.disconnected.localizedDescription
                self.nextRefreshAt = Date().addingTimeInterval(30)
            }
        }
    }

    var bucket: LimitBucket? {
        guard let buckets = snapshot?.limits.buckets else { return nil }
        return buckets.first(where: { $0.id == preferences.bucketID }) ?? buckets.first
    }
    func window(_ period: QuotaPeriod) -> QuotaWindow? { bucket?.window(period) }
    var selectedWindow: QuotaWindow? { window(preferences.selectedPeriod) }
    var isStale: Bool {
        guard let snapshot else { return false }
        return lastError != nil || now.timeIntervalSince(snapshot.fetchedAt) > max(180, preferences.refreshInterval * 2)
    }
    var blocked: Bool { snapshot?.limits.ordinaryUsageAllowed == false || bucket?.isBlocked == true }
    var statusText: String {
        if isLoggingIn { return "等待浏览器登录" }
        if isSleeping { return "休眠中" }
        if lastError != nil { return snapshot == nil ? "尚未连接" : "上次读取" }
        if isRefreshing && snapshot == nil { return "正在连接 Codex" }
        if blocked { return "套餐使用受限" }
        if isStale { return "数据待更新" }
        if snapshot != nil && bucket?.hasWindow == false { return "额度窗口不可用" }
        return snapshot == nil ? "等待同步" : "已同步"
    }
    var updateDescription: String {
        guard let date = snapshot?.fetchedAt else { return "自动读取本机 Codex 登录" }
        let age = max(0, Int(now.timeIntervalSince(date)))
        if age < 60 { return "\(age) 秒前更新" }
        return "\(age / 60) 分钟前更新"
    }

    func start() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.now = Date()
                if !self.isSleeping && !self.isRefreshing && !self.isLoggingIn && self.now >= self.nextRefreshAt {
                    await self.refresh()
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
        Task { await refresh() }
    }

    func refresh(reconnect: Bool = false) async {
        guard !isRefreshing, !isSleeping, !isLoggingIn else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if reconnect { client.stop() }
        do {
            try await client.connect(customPath: preferences.customCLI)
            cliPath = client.executableURL?.path
            let accountData = try await client.request("account/read", params: ["refreshToken": false])
            let accountResult = try JSONDecoder().decode(AccountResponse.self, from: accountData)
            guard let account = accountResult.account else {
                snapshot = nil
                throw OrbitError.loginRequired
            }
            guard account.isChatGPT else {
                snapshot = nil
                throw OrbitError.unsupportedAccount
            }
            if let old = snapshot, old.account.identity != account.identity { snapshot = nil }
            let revision = accountRevision
            let limitData = try await client.request("account/rateLimits/read")
            let limits = try JSONDecoder().decode(LimitsResponse.self, from: limitData)
            // A login switch during an in-flight request cannot attach another account's data.
            let checkedData = try await client.request("account/read", params: ["refreshToken": false])
            let checked = try JSONDecoder().decode(AccountResponse.self, from: checkedData)
            guard checked.account?.identity == account.identity, accountRevision == revision else {
                snapshot = nil; nextRefreshAt = Date().addingTimeInterval(2)
                lastError = "账号已切换，正在重新读取。"
                return
            }
            snapshot = UsageSnapshot(account: account, limits: limits, fetchedAt: Date())
            now = Date(); lastError = nil; needsLogin = false; failures = 0
            nextRefreshAt = Date().addingTimeInterval(preferences.refreshInterval)
            await sendWeeklyAlerts()
        } catch {
            failures += 1
            lastError = (error as? OrbitError)?.localizedDescription ?? "无法读取额度，请检查网络或更新 Codex。"
            if let orbitError = error as? OrbitError {
                switch orbitError {
                case .loginRequired, .unsupportedAccount: needsLogin = true
                case .rpc(_, let message):
                    let value = message.lowercased()
                    needsLogin = value.contains("401") || value.contains("unauthorized") || value.contains("not logged")
                    if needsLogin { snapshot = nil }
                default: break
                }
            }
            // Backoff remains bounded, including disconnected/offline machines.
            let delay = min(600.0, max(preferences.refreshInterval, 30 * pow(2, Double(min(failures - 1, 4)))))
            nextRefreshAt = Date().addingTimeInterval(delay)
            if case OrbitError.timeout = error { client.stop() }
        }
    }

    func login() async {
        guard !isLoggingIn, !isRefreshing else { return }
        isLoggingIn = true
        lastError = nil
        do {
            try await client.connect(customPath: preferences.customCLI)
            let data = try await client.request("account/login/start", params: ["type": "chatgpt"])
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let string = result["authUrl"] as? String, let url = URL(string: string),
                  url.scheme == "https", let id = result["loginId"] as? String else { throw OrbitError.malformedResponse }
            loginID = id
            snapshot = nil
            NSWorkspace.shared.open(url)
            loginTimeout?.cancel()
            loginTimeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
                await self?.cancelLogin()
            }
        } catch {
            isLoggingIn = false
            lastError = (error as? OrbitError)?.localizedDescription ?? "无法启动登录，请在 Codex 中完成登录后重试。"
        }
    }

    func cancelLogin() async {
        loginTimeout?.cancel()
        if let loginID { _ = try? await client.request("account/login/cancel", params: ["loginId": loginID], timeout: 5) }
        loginID = nil; isLoggingIn = false
        needsLogin = true
        nextRefreshAt = Date().addingTimeInterval(preferences.refreshInterval)
    }

    private func notification(method: String, params: Data?) {
        if method == "account/login/completed" {
            guard isLoggingIn, let params,
                  let result = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
                  result["loginId"] as? String == loginID else { return }
            isLoggingIn = false; loginID = nil; loginTimeout?.cancel()
            if result["success"] as? Bool == true { Task { await refresh() } }
            else { needsLogin = true; lastError = "登录未完成，请重试。" }
        } else if method == "account/updated" {
            accountRevision += 1
            snapshot = nil
            scheduleEventRefresh()
        } else if method == "account/rateLimits/updated" {
            // Events may contain one bucket only. Read a complete authoritative snapshot.
            scheduleEventRefresh()
        }
    }

    private func scheduleEventRefresh() {
        eventRefresh?.cancel()
        eventRefresh = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            await self?.refresh()
        }
    }

    func setNotifications(_ enabled: Bool) async {
        preferences.notifications = enabled
        guard enabled else { notificationMessage = nil; return }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            guard preferences.notifications else { return }
            notificationMessage = allowed ? "已开启：每周剩余 ≤30% 时通知，同一周只提醒一次。" : "请在系统设置 → 通知中允许 Codex Orbit。"
            if allowed {
                await sendWeeklyAlerts()
            }
        } catch {
            notificationMessage = "无法请求通知权限，请在系统设置 → 通知中检查 Codex Orbit。"
        }
    }

    private func sendWeeklyAlerts() async {
        guard allowsNotifications, preferences.notifications, !isSendingWeeklyAlert,
              snapshot != nil, !isStale, lastError == nil, !isSleeping else { return }
        isSendingWeeklyAlert = true
        defer { isSendingWeeklyAlert = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            notificationMessage = "请在系统设置 → 通知中允许 Codex Orbit。"
            return
        }
        guard preferences.notifications, let snapshot, !isStale, lastError == nil, !isSleeping else { return }
        let identity = snapshot.limits.accountId ?? snapshot.account.identity
        let revision = accountRevision
        for bucket in snapshot.limits.buckets {
            guard preferences.notifications, accountRevision == revision,
                  self.snapshot?.account.identity == snapshot.account.identity,
                  self.snapshot?.limits.accountId == snapshot.limits.accountId else { return }
            guard let alert = weeklyAlerts.pending(account: identity, bucket: bucket, at: Date()),
                  let window = bucket.window(.weekly) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Codex 每周额度提醒"
            content.body = "每周额度剩余 \(window.percentText)，已达到 30% 提醒线。\(window.resetDescription(at: Date()))。"
            if snapshot.limits.buckets.count > 1 { content.subtitle = bucket.displayName }
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
                // Persist only after the system accepts the request; failed sends can retry.
                weeklyAlerts.markDelivered(alert, at: Date())
                if let data = try? JSONEncoder().encode(weeklyAlerts) { defaults.set(data, forKey: "weeklyAlertLedger") }
            } catch {
                notificationMessage = "每周提醒发送失败，将在下次刷新时重试。"
            }
        }
    }

    func sendTestNotification() async {
        guard preferences.notifications else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            notificationMessage = "请在系统设置 → 通知中允许 Codex Orbit。"
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Codex Orbit · 测试通知"
        content.body = "通知已就绪。每周额度剩余 30% 或以下时，这里会提醒你。"
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "orbit-notification-test", content: content, trigger: nil))
            notificationMessage = "测试通知已交给系统。每周提醒同一周只发送一次。"
        } catch {
            notificationMessage = "测试通知发送失败，请检查系统通知设置。"
        }
    }

    func sleep() {
        isSleeping = true
        client.stop()
    }
    func wake() {
        isSleeping = false
        nextRefreshAt = Date()
        Task { await refresh(reconnect: true) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        eventRefresh?.cancel(); loginTimeout?.cancel()
        client.stop()
    }
}
