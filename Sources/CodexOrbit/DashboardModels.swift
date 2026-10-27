import Foundation

enum DashboardRange: Int, CaseIterable, Identifiable {
    case today = 1, week = 7, month = 30
    var id: Int { rawValue }
    var title: String { self == .today ? "今日" : (self == .week ? "7天" : "30天") }
}

enum DashboardFormat {
    static func tokens(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return "—" }
        let units: [(Double, String)] = [(1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")]
        for (divisor, suffix) in units where Double(value) >= divisor {
            var text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value) / divisor)
            if text.hasSuffix(".0") { text.removeLast(2) }
            return text + suffix
        }
        return String(value)
    }
    static func relative(_ timestamp: TimeInterval, now: Date) -> String {
        let age = max(0, now.timeIntervalSince1970 - timestamp)
        if age < 60 { return "刚刚" }
        if age < 3600 { return "\(Int(age / 60))分钟前" }
        if age < 86400 { return "\(Int(age / 3600))小时前" }
        return "\(Int(age / 86400))天前"
    }
    static func reset(_ window: QuotaWindow?, now: Date) -> String {
        guard let date = window?.resetDate else { return "时间未知" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "待更新" }
        if (window?.windowDurationMins ?? 0) < 1440 {
            let minutes = max(1, Int(ceil(seconds / 60)))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}

struct AccountTokenSummary: Decodable {
    let lifetimeTokens: Int64?
    let peakDailyTokens: Int64?
    let currentStreakDays: Int?
}
struct AccountDailyTokens: Decodable, Equatable {
    let startDate: String
    let tokens: Int64
}
struct AccountTokenDashboard: Decodable {
    let summary: AccountTokenSummary
    let dailyUsageBuckets: [AccountDailyTokens]?
}
struct DashboardDay: Identifiable, Equatable {
    let id: String
    let tokens: Int64?
}
struct DashboardTrend {
    let days: [DashboardDay]
    var knownDays: Int { days.filter { $0.tokens != nil }.count }
    var total: Int64? {
        guard knownDays > 0 else { return nil }
        return days.compactMap(\.tokens).reduce(0) { value, next in
            let sum = value.addingReportingOverflow(next)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }
    var peak: Int64 { max(1, days.compactMap(\.tokens).max() ?? 0) }

    init(buckets: [AccountDailyTokens]?, range: DashboardRange, now: Date, calendar: Calendar = .autoupdatingCurrent) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        var values: [String: Int64] = [:]
        for bucket in buckets ?? [] {
            guard bucket.tokens >= 0, let date = formatter.date(from: bucket.startDate),
                  formatter.string(from: date) == bucket.startDate else { continue }
            // Duplicate days replace one another rather than counting usage twice.
            values[bucket.startDate] = bucket.tokens
        }
        days = (0..<range.rawValue).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = formatter.string(from: date)
            return DashboardDay(id: key, tokens: values[key])
        }
    }
}

struct DashboardSession: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let cwd: String
    let updatedAt: TimeInterval
    let model: String?
    var localTokens: Int64? = nil
    private enum CodingKeys: String, CodingKey { case id, name, cwd, updatedAt, model }

    var title: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未命名会话" : String(value.prefix(120))
    }
    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
}
struct DashboardSessionsResponse: Decodable { let data: [DashboardSession] }
