import Foundation
import SQLite3

@main
struct DashboardTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ title: String) {
        guard condition() else { fatalError("FAIL: \(title)") }
        count += 1
    }
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = ISO8601DateFormatter().date(from: "2026-10-27T01:30:00Z")!
        let buckets = [AccountDailyTokens(startDate: "2026-10-27", tokens: 10), AccountDailyTokens(startDate: "2026-10-26", tokens: 20), AccountDailyTokens(startDate: "2026-10-26", tokens: 25), AccountDailyTokens(startDate: "2026-10-25", tokens: -1), AccountDailyTokens(startDate: "not-a-date", tokens: 50)]
        let week = DashboardTrend(buckets: buckets, range: .week, now: now, calendar: calendar)
        check(week.days.count == 7 && week.days.first?.id == "2026-10-21" && week.days.last?.id == "2026-10-27", "range uses client calendar and sorts ascending")
        check(week.knownDays == 2 && week.total == 35, "duplicates replace rather than inflate totals")
        check(week.days[4].tokens == nil, "negative data is not a legitimate zero")
        check(week.days[0].tokens == nil, "missing dates remain unknown")
        check(DashboardTrend(buckets: nil, range: .today, now: now, calendar: calendar).total == nil, "absent data is not zero")
        check(DashboardTrend(buckets: [], range: .month, now: now, calendar: calendar).total == nil, "empty service response does not fabricate a month of zeros")
        let zero = DashboardTrend(buckets: [AccountDailyTokens(startDate: "2026-10-27", tokens: 0)], range: .today, now: now, calendar: calendar)
        check(zero.total == 0 && zero.knownDays == 1 && zero.peak == 1, "explicit service zero is retained and charts avoid divide-by-zero")
        let huge = DashboardTrend(buckets: [AccountDailyTokens(startDate: "2026-10-27", tokens: Int64.max), AccountDailyTokens(startDate: "2026-10-26", tokens: 1)], range: .week, now: now, calendar: calendar)
        check(huge.total == Int64.max, "large totals cannot overflow")
        check(DashboardFormat.tokens(nil) == "—" && DashboardFormat.tokens(-1) == "—", "unavailable tokens never read as zero")
        check(DashboardFormat.tokens(0) == "0" && DashboardFormat.tokens(1250) == "1.2K" && DashboardFormat.tokens(6_200_000) == "6.2M", "compact token units")
        check(DashboardFormat.relative(now.timeIntervalSince1970 + 5, now: now) == "刚刚", "future timestamps do not show negative ages")
        let rowData = Data("{\"id\":\"x\",\"name\":null,\"cwd\":\"/tmp/project\",\"updatedAt\":1,\"model\":null,\"preview\":\"PRIVATE_PROMPT\"}".utf8)
        let row = try JSONDecoder().decode(DashboardSession.self, from: rowData)
        check(row.title == "未命名会话" && row.project == "project" && row.localTokens == nil, "unnamed sessions do not expose prompt previews")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-dashboard-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dbFile = folder.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(dbFile.path, &db) == SQLITE_OK else { fatalError("Cannot create fixture") }
        guard sqlite3_exec(db, "CREATE TABLE threads (id TEXT, tokens_used INTEGER); INSERT INTO threads VALUES ('wanted',6200000),('unknown',0),('negative',-1),('unrelated',900);", nil, nil, nil) == SQLITE_OK else { fatalError("Cannot populate fixture") }
        sqlite3_close(db)
        let before = try Data(contentsOf: dbFile)
        let values = LocalSessionTokens.read(ids: ["wanted", "unknown", "negative"], home: folder)
        check(values == ["wanted": 6_200_000], "SQLite fallback only returns requested positive measured records")
        check(LocalSessionTokens.read(ids: ["wanted' OR 1=1 --"], home: folder).isEmpty, "session IDs are SQL bound parameters")
        check(LocalSessionTokens.read(ids: [], home: folder).isEmpty, "empty lookup does not scan all sessions")
        let after = try Data(contentsOf: dbFile)
        check(after == before, "metadata DB remains byte-for-byte unchanged")
        print("PASS: \(count) dashboard dates, totals, privacy and read-only metadata checks")
    }
}
