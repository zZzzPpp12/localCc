import Foundation
import Combine

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var tokens: AccountTokenDashboard?
    @Published private(set) var sessions: [DashboardSession] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var tokenError: String?
    @Published private(set) var sessionError: String?
    @Published private(set) var fetchedAt: Date?
    private let client = AppServerClient()
    private var identity: String?
    private var generation = 0
    private var nextAttempt = Date.distantPast
    var refreshDue: Bool { !isRefreshing && Date() >= nextAttempt }

    func synchronize(account: String?) {
        guard identity != account else { return }
        generation += 1
        client.stop(); identity = account
        tokens = nil; sessions = []; fetchedAt = nil
        tokenError = nil; sessionError = nil; isRefreshing = false; nextAttempt = .distantPast
    }

    func refresh(account: String?, customPath: String, force: Bool = false) async {
        synchronize(account: account)
        guard let account, !isRefreshing, force || Date() >= nextAttempt else { return }
        isRefreshing = true
        let revision = generation
        defer { if generation == revision { isRefreshing = false } }
        do {
            try await client.connect(customPath: customPath)
            let before = try JSONDecoder().decode(AccountResponse.self, from: await client.request("account/read", params: ["refreshToken": false], timeout: 8))
            guard before.account?.identity == account else {
                tokens = nil; sessions = []; fetchedAt = nil
                throw OrbitError.loginRequired
            }
            async let tokenData: Data? = try? client.request("account/usage/read", params: [:], timeout: 8)
            async let sessionData: Data? = try? client.request("thread/list", params: ["limit": 4, "sortKey": "updated_at", "sortDirection": "desc", "useStateDbOnly": true], timeout: 8)
            let values = await (tokenData, sessionData)
            var rows = values.1.flatMap { try? JSONDecoder().decode(DashboardSessionsResponse.self, from: $0).data } ?? []
            let ids = rows.map(\.id)
            let local = await Task.detached(priority: .utility) { LocalSessionTokens.read(ids: ids) }.value
            for index in rows.indices { rows[index].localTokens = local[rows[index].id] }
            let checked = try JSONDecoder().decode(AccountResponse.self, from: await client.request("account/read", params: ["refreshToken": false], timeout: 8))
            guard generation == revision, identity == account else { return }
            guard checked.account?.identity == account else {
                tokens = nil; sessions = []; fetchedAt = nil
                tokenError = "账号已切换，等待额度同步"; sessionError = tokenError
                nextAttempt = Date().addingTimeInterval(5)
                return
            }
            tokens = values.0.flatMap { try? JSONDecoder().decode(AccountTokenDashboard.self, from: $0) }
            sessions = rows
            tokenError = tokens == nil ? "暂未取得 Token 汇总" : nil
            sessionError = values.1 == nil ? "暂未取得本机会话" : nil
            fetchedAt = Date(); nextAttempt = Date().addingTimeInterval(60)
        } catch {
            guard generation == revision else { return }
            tokenError = "Token 数据暂不可用"; sessionError = "会话数据暂不可用"
            nextAttempt = Date().addingTimeInterval(30)
        }
    }
    func stop() { generation += 1; client.stop(); isRefreshing = false; nextAttempt = .distantPast }
}
