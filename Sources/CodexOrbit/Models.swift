import Foundation
import CryptoKit

enum QuotaPeriod: String, Codable, CaseIterable {
    case short, weekly
    var fallbackTitle: String { self == .short ? "短周期" : "长周期" }
}

struct QuotaWindow: Codable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var remaining: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }
    var fraction: Double { (remaining ?? 0) / 100 }
    var percentText: String { remaining.map { "\(Int($0.rounded()))%" } ?? "—" }
    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
    var title: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "周期未知" }
        if minutes == 10080 { return "每周额度" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天额度" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
    var shortTitle: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "未知" }
        if minutes == 10080 { return "每周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
    func resetDescription(at now: Date) -> String {
        guard let resetDate else { return "重置时间未知" }
        let seconds = resetDate.timeIntervalSince(now)
        guard seconds > 0 else { return "等待服务器更新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分后重置" }
        return "\(minutes) 分钟后重置"
    }
}

struct CreditSnapshot: Codable, Equatable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
}

struct LimitBucket: Codable, Equatable, Identifiable {
    var limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let planType: String?
    let credits: CreditSnapshot?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?

    var id: String { limitId ?? "codex" }
    var displayName: String { limitName?.isEmpty == false ? limitName! : id }
    // Sort by actual duration, not the historically used primary/secondary names.
    // With unknown durations preserve the server's slots without inventing a period.
    var orderedWindows: [QuotaWindow] {
        let windows = [primary, secondary].compactMap { $0 }
        guard windows.allSatisfy({ ($0.windowDurationMins ?? 0) > 0 }) else { return windows }
        return windows.sorted { $0.windowDurationMins! < $1.windowDurationMins! }
    }
    func window(_ period: QuotaPeriod) -> QuotaWindow? {
        let windows = orderedWindows
        if windows.count == 1, let only = windows.first {
            if let minutes = only.windowDurationMins, minutes > 0 {
                let belongsTo: QuotaPeriod = minutes >= 10080 ? .weekly : .short
                return period == belongsTo ? only : nil
            }
            return period == .short ? primary : secondary
        }
        return period == .short ? windows.first : (windows.count > 1 ? windows.last : nil)
    }
    var hasWindow: Bool { primary != nil || secondary != nil }
    var isBlocked: Bool { rateLimitReachedType != nil || spendControlReached == true }
}

struct LimitsResponse: Codable {
    let rateLimits: LimitBucket?
    let rateLimitsByLimitId: [String: LimitBucket]?
    let accountId: String?
    let ordinaryUsageAllowed: Bool?

    var buckets: [LimitBucket] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.map { key, value in
                var bucket = value
                bucket.limitId = key
                return bucket
            }.sorted { a, b in
                if a.id == b.id { return false }
                if a.id == "codex" { return true }
                if b.id == "codex" { return false }
                return a.id < b.id
            }
        }
        return rateLimits.map { [$0] } ?? []
    }
}

struct AccountInfo: Codable, Equatable {
    let type: String
    let email: String?
    let planType: String?
    let id: String?

    var identity: String { "\(type):\(id ?? email ?? "unknown")" }
    var isChatGPT: Bool { type == "chatgpt" || type == "chatgptAuthTokens" }
    var planName: String {
        switch planType {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free": return "Free"
        case "team": return "Team"
        case "business": return "Business"
        default: return planType?.capitalized ?? "ChatGPT"
        }
    }
}

struct AccountResponse: Codable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool?
}

struct UsageSnapshot {
    let account: AccountInfo
    let limits: LimitsResponse
    let fetchedAt: Date
}

enum OrbitError: LocalizedError {
    case missingCLI, loginRequired, unsupportedAccount, disconnected, timeout(String), malformedResponse
    case rpc(Int, String)
    case launch(String)

    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex。请安装 Codex，或在设置中选择 codex 可执行文件。"
        case .loginRequired: return "请先使用 ChatGPT 账号登录 Codex。"
        case .unsupportedAccount: return "当前为 API Key 登录，请使用 ChatGPT 账号登录以读取套餐额度。"
        case .disconnected: return "Codex 连接已断开，稍后会自动重连。"
        case .timeout: return "读取 Codex 超时，请检查网络后重试。"
        case .malformedResponse: return "Codex 返回了无法识别的数据，请更新 Codex 后重试。"
        case .rpc(_, let message):
            let lower = message.lowercased()
            if lower.contains("401") || lower.contains("unauthorized") || lower.contains("not logged") { return "Codex 登录已失效，请重新登录。" }
            if lower.contains("429") || lower.contains("rate limit") { return "额度服务请求过于频繁，稍后自动重试。" }
            return "额度服务暂时不可用，请稍后重试。"
        case .launch: return "无法启动 Codex，请在设置中检查 CLI 路径。"
        }
    }
}

enum QuotaSignal: String {
    case green, yellow, red, unknown

    init(remaining: Double?, stale: Bool = false) {
        guard !stale, let remaining, remaining.isFinite else { self = .unknown; return }
        if remaining >= 60 { self = .green }
        else if remaining >= 30 { self = .yellow }
        else { self = .red }
    }

    var description: String {
        switch self {
        case .green: return "绿灯，额度充足"
        case .yellow: return "黄灯，注意用量"
        case .red: return "红灯，额度偏低"
        case .unknown: return "灰灯，等待有效数据"
        }
    }
}

struct WeeklyAlert: Equatable {
    let identifier: String
    let resetsAt: TimeInterval
}

/// One accepted notification per account, bucket and weekly reset, including across launches.
/// A first reading below 30% catches consumption while the app was closed.
struct WeeklyAlertLedger: Codable {
    private var delivered: [String: TimeInterval] = [:]

    func pending(account: String, bucket: LimitBucket, at now: Date) -> WeeklyAlert? {
        guard let window = bucket.window(.weekly), window.windowDurationMins == 10080,
              let remaining = window.remaining, remaining <= 30,
              let reset = window.resetsAt, reset.isFinite, reset > now.timeIntervalSince1970 else { return nil }
        // The persisted key never contains the account's email or raw identifier.
        let key = try! JSONEncoder().encode([account, bucket.id, String(reset), "weekly-30"])
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let identifier = "orbit-weekly-\(digest)"
        guard delivered[identifier] == nil else { return nil }
        return WeeklyAlert(identifier: identifier, resetsAt: reset)
    }

    mutating func markDelivered(_ alert: WeeklyAlert, at now: Date) {
        delivered = delivered.filter { $0.value > now.timeIntervalSince1970 }
        delivered[alert.identifier] = alert.resetsAt
    }
}
