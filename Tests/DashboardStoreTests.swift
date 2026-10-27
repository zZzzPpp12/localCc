import Foundation

@main @MainActor
struct DashboardStoreTests {
    static func main() async {
        let path = CommandLine.arguments[1]
        setenv("ORBIT_DASHBOARD_TEST_MODE", "normal", 1)
        let store = DashboardStore()
        await store.refresh(account: "chatgpt:account-a", customPath: path)
        guard store.tokens?.summary.lifetimeTokens == 1000, store.sessions.count == 1 else { fatalError("Real refresh path failed") }
        let date = store.fetchedAt
        await store.refresh(account: "chatgpt:account-a", customPath: path)
        guard store.fetchedAt == date else { fatalError("Hover caused redundant refresh") }
        store.synchronize(account: nil)
        guard store.tokens == nil, store.sessions.isEmpty else { fatalError("Logout retained another account's stats") }
        store.stop()
        setenv("ORBIT_DASHBOARD_TEST_MODE", "switch", 1)
        let switching = DashboardStore()
        await switching.refresh(account: "chatgpt:account-a", customPath: path)
        guard switching.tokens == nil, switching.sessions.isEmpty else { fatalError("Account switch attached stale results") }
        switching.stop()
        setenv("ORBIT_DASHBOARD_TEST_MODE", "missing", 1)
        let missing = DashboardStore()
        await missing.refresh(account: "chatgpt:account-a", customPath: path)
        guard missing.tokens == nil, missing.tokenError != nil, missing.sessions.count == 1 else { fatalError("Missing optional endpoint poisoned session list") }
        missing.stop()
        setenv("ORBIT_DASHBOARD_TEST_MODE", "slow", 1)
        let cancelled = DashboardStore()
        let refresh = Task { await cancelled.refresh(account: "chatgpt:account-a", customPath: path) }
        try? await Task.sleep(nanoseconds: 40_000_000)
        cancelled.synchronize(account: "chatgpt:account-b")
        await refresh.value
        guard cancelled.tokens == nil, cancelled.sessions.isEmpty, !cancelled.isRefreshing else { fatalError("Cancelled fetch republished stale account data") }
        cancelled.stop()
        unsetenv("ORBIT_DASHBOARD_TEST_MODE")
        print("PASS: dashboard live client path, refresh throttle, optional API errors, logout and in-flight account switch")
    }
}
