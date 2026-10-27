import Foundation
import CryptoKit

enum QuotaHUDLevel: String, Codable {
    case low, exhausted

    init?(remaining: Double?) {
        guard let remaining, remaining.isFinite, remaining >= 0, remaining <= 10 else { return nil }
        self = remaining == 0 ? .exhausted : .low
    }
    var title: String { self == .exhausted ? "已耗尽" : "即将耗尽" }
    var callout: String { self == .exhausted ? "额度已耗尽" : "额度快见底…" }
    var duration: TimeInterval { self == .exhausted ? 10 : 8 }
}

struct QuotaHUDAlert: Equatable, Identifiable {
    // Only the hashed cycle ID and reset are persisted, never account details or usage.
    let cycleID: String
    let period: QuotaPeriod
    let bucketName: String?
    let window: QuotaWindow
    let level: QuotaHUDLevel
    let isPreview: Bool
    var id: String { cycleID + ":" + level.rawValue }
    var periodTitle: String { window.shortTitle + " 额度" }
    var remainingText: String {
        guard let value = window.remaining else { return "—" }
        // A nonzero fraction must never be presented as exhausted / 0%.
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    static func candidates(snapshot: UsageSnapshot, at now: Date) -> [QuotaHUDAlert] {
        var alerts: [QuotaHUDAlert] = []
        for bucket in snapshot.limits.buckets {
            for period in QuotaPeriod.allCases {
                guard let window = bucket.window(period), let minutes = window.windowDurationMins, minutes > 0,
                      let level = QuotaHUDLevel(remaining: window.remaining),
                      let reset = window.resetsAt, reset.isFinite, reset > now.timeIntervalSince1970 else { continue }
                let key = try! JSONEncoder().encode([snapshot.account.identity, bucket.id, String(minutes), String(reset)])
                let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
                alerts.append(QuotaHUDAlert(cycleID: digest, period: period,
                                           bucketName: bucket.id == "codex" ? nil : bucket.displayName,
                                           window: window, level: level, isPreview: false))
            }
        }
        return alerts.sorted {
            if $0.level != $1.level { return $0.level == .exhausted }
            if $0.period != $1.period { return $0.period == .short }
            return $0.cycleID < $1.cycleID
        }
    }

    static func preview(_ level: QuotaHUDLevel, at now: Date = Date()) -> QuotaHUDAlert {
        QuotaHUDAlert(cycleID: "preview", period: .short, bucketName: nil,
                      window: QuotaWindow(usedPercent: level == .exhausted ? 100 : 92, windowDurationMins: 300,
                                          resetsAt: now.addingTimeInterval(3720).timeIntervalSince1970),
                      level: level, isPreview: true)
    }
}

struct QuotaHUDLedger: Codable {
    private struct Delivery: Codable { let level: QuotaHUDLevel; let resetsAt: TimeInterval }
    private var delivered: [String: Delivery] = [:]

    func shouldPresent(_ alert: QuotaHUDAlert) -> Bool {
        guard !alert.isPreview else { return false }
        guard let previous = delivered[alert.cycleID] else { return true }
        // Exhaustion supersedes low quota, and a later correction cannot send low again.
        return previous.level == .low && alert.level == .exhausted
    }

    mutating func markPresented(_ alert: QuotaHUDAlert, at now: Date) {
        guard !alert.isPreview, let reset = alert.window.resetsAt else { return }
        delivered = delivered.filter { $0.value.resetsAt > now.timeIntervalSince1970 }
        delivered[alert.cycleID] = Delivery(level: alert.level, resetsAt: reset)
    }
}
