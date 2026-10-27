import Foundation

@main
struct ModelTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        passed += 1
    }
    static func decode(_ text: String) throws -> LimitsResponse {
        try JSONDecoder().decode(LimitsResponse.self, from: Data(text.utf8))
    }
    static func makeWindow(_ used: Double?, _ duration: Int? = 300, _ reset: Double? = 2000000000) -> QuotaWindow {
        QuotaWindow(usedPercent: used, windowDurationMins: duration, resetsAt: reset)
    }
    static func makeBucket(_ used: Double, reset: Double = 2000000000, weeklyUsed: Double = 20) -> LimitBucket {
        LimitBucket(limitId: "codex", limitName: nil, primary: makeWindow(used, 300, reset), secondary: makeWindow(weeklyUsed, 10080, reset + 200000), planType: "plus", credits: nil, rateLimitReachedType: nil, spendControlReached: nil)
    }
    static func main() throws {
        check(makeWindow(19).remaining == 81, "used and remaining are not confused")
        check(makeWindow(125).remaining == 0, "overdrawn usage clamps at zero")
        check(makeWindow(-8).remaining == 100, "negative usage clamps at one hundred")
        check(makeWindow(nil).remaining == nil && makeWindow(nil).percentText == "—", "unknown is never zero")
        check(makeWindow(.nan).remaining == nil, "invalid number is unknown")
        check(makeWindow(0, 300).title == "5 小时额度", "short window label")
        check(makeWindow(0, 10080).title == "每周额度", "weekly window label")
        check(makeWindow(0, 60).shortTitle == "1h", "durations are not hard coded")
        check(makeWindow(0, nil).title == "周期未知", "missing duration not assumed to be five hours")
        let at = Date(timeIntervalSince1970: 2000000000)
        check(makeWindow(50, 300, 2000000061).resetDescription(at: at) == "2 分钟后重置", "countdown rounds up")
        check(makeWindow(50).resetDescription(at: at) == "等待服务器更新", "elapsed reset does not invent a refill")
        check(makeWindow(50, 300, nil).resetDescription(at: at) == "重置时间未知", "unknown reset")
        check(makeWindow(50).remaining == 50, "countdown cannot alter measured percentage")
        let multiple = try decode("""
        {"rateLimits":{"limitId":"old","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":32,"windowDurationMins":120}},"codex":{"primary":{"usedPercent":19,"windowDurationMins":300},"secondary":{"usedPercent":14,"windowDurationMins":10080}}}}
        """)
        check(multiple.buckets.count == 2, "all quota groups retained")
        check(multiple.buckets.first?.id == "codex", "Codex is initial group")
        check(multiple.buckets.first?.window(.short)?.remaining == 81, "multi-bucket response preferred")
        let legacy = try decode("""
        {"rateLimits":{"primary":{"usedPercent":40,"windowDurationMins":300}},"rateLimitsByLimitId":null}
        """)
        check(legacy.buckets.first?.window(.short)?.remaining == 60, "legacy fallback")
        let missing = try decode("""
        {"rateLimits":{"primary":null,"secondary":null}}
        """)
        check(missing.buckets.first?.window(.short) == nil, "absent primary")
        check(missing.buckets.first?.window(.weekly) == nil, "absent secondary")
        let reverse = try decode("""
        {"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080},"secondary":{"usedPercent":60,"windowDurationMins":300}}}
        """)
        check(reverse.buckets.first?.window(.short)?.remaining == 40, "server slot order cannot swap the periods")
        let loneWeek = try decode("""
        {"rateLimits":{"primary":null,"secondary":{"usedPercent":6,"windowDurationMins":10080}}}
        """)
        check(loneWeek.buckets.first?.window(.short) == nil, "weekly-only response leaves short period unknown")
        check(loneWeek.buckets.first?.window(.weekly)?.remaining == 94, "weekly-only response stays on inner ring")
        let sparse = try decode("""
        {"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300}},"rateLimitsByLimitId":{"codex":{"primary":null,"secondary":null}}}
        """)
        check(sparse.buckets.first?.hasWindow == false, "no stale legacy fallback for an authoritative empty bucket")
        check(QuotaSignal(remaining: 100) == .green, "full quota is green")
        check(QuotaSignal(remaining: 60) == .green, "sixty percent stays green")
        check(QuotaSignal(remaining: 59.99) == .yellow, "below sixty is yellow")
        check(QuotaSignal(remaining: 30) == .yellow, "thirty percent stays yellow")
        check(QuotaSignal(remaining: 29.99) == .red, "below thirty is red")
        check(QuotaSignal(remaining: 0) == .red, "empty quota is red")
        check(QuotaSignal(remaining: nil) == .unknown, "missing quota never shows green")
        check(QuotaSignal(remaining: .nan) == .unknown, "invalid quota never shows green")
        check(QuotaSignal(remaining: 100, stale: true) == .unknown, "stale quota has a neutral light")
        var ledger = WeeklyAlertLedger()
        check(ledger.pending(account: "a", bucket: makeBucket(100), at: at) == nil, "short quota never sends weekly alert")
        check(ledger.pending(account: "a", bucket: makeBucket(0, weeklyUsed: 69.99), at: at) == nil, "above thirty does not notify")
        let thirty = makeBucket(0, weeklyUsed: 70)
        let alert = ledger.pending(account: "a", bucket: thirty, at: at)!
        check(alert.resetsAt == thirty.secondary?.resetsAt, "exactly thirty notifies in the weekly window")
        check(ledger.pending(account: "a", bucket: thirty, at: at) == alert, "failed or unauthorized delivery stays retryable")
        check(ledger.pending(account: "a", bucket: makeBucket(0, weeklyUsed: 90), at: at) != nil, "first reading below thirty catches offline consumption")
        ledger.markDelivered(alert, at: at)
        check(ledger.pending(account: "a", bucket: thirty, at: at) == nil, "repeated polling does not resend")
        check(ledger.pending(account: "a", bucket: makeBucket(0, weeklyUsed: 95), at: at) == nil, "further decline does not send extra thresholds")
        _ = ledger.pending(account: "a", bucket: makeBucket(0, weeklyUsed: 50), at: at)
        check(ledger.pending(account: "a", bucket: thirty, at: at) == nil, "fluctuation does not spam same week")
        let encodedLedger = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(WeeklyAlertLedger.self, from: encodedLedger)
        check(restored.pending(account: "a", bucket: thirty, at: at) == nil, "restart preserves deduplication")
        check(restored.pending(account: "b", bucket: thirty, at: at) != nil, "accounts do not suppress one another")
        var otherBucket = thirty
        otherBucket.limitId = "other"
        check(restored.pending(account: "a", bucket: otherBucket, at: at) != nil, "separate quota buckets notify independently")
        check(restored.pending(account: "a", bucket: makeBucket(0, reset: 2000600000, weeklyUsed: 70), at: at) != nil, "new weekly reset permits a reminder")
        check(restored.pending(account: "a", bucket: makeBucket(0, reset: 1999000000, weeklyUsed: 70), at: at) == nil, "expired server data cannot send an alert")
        let absent = try decode("""
        {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":null,"windowDurationMins":10080,"resetsAt":2000200000}}}
        """)
        check(restored.pending(account: "a", bucket: absent.buckets[0], at: at) == nil, "unknown weekly quota does not notify")
        let unknownReset = try decode("""
        {"rateLimits":{"secondary":{"usedPercent":90,"windowDurationMins":10080}}}
        """)
        check(restored.pending(account: "a", bucket: unknownReset.buckets[0], at: at) == nil, "missing reset cannot invent a weekly period")
        let month = try decode("""
        {"rateLimits":{"secondary":{"usedPercent":90,"windowDurationMins":43200,"resetsAt":2000200000}}}
        """)
        check(restored.pending(account: "a", bucket: month.buckets[0], at: at) == nil, "monthly quota is not mislabeled as weekly")
        func hud(_ used: Double, week: Double = 20, account: String = "hud-a", reset: Double = 2000003600) -> [QuotaHUDAlert] {
            let snapshot = UsageSnapshot(account: AccountInfo(type: "chatgpt", email: account, planType: "plus", id: nil),
                                         limits: LimitsResponse(rateLimits: makeBucket(used, reset: reset, weeklyUsed: week), rateLimitsByLimitId: nil, accountId: nil, ordinaryUsageAllowed: true), fetchedAt: at)
            return QuotaHUDAlert.candidates(snapshot: snapshot, at: at)
        }
        check(QuotaHUDLevel(remaining: 10.01) == nil, "HUD ignores above ten percent")
        check(QuotaHUDLevel(remaining: 10) == .low, "HUD includes exact ten percent")
        check(QuotaHUDLevel(remaining: 0.01) == .low, "fractional positive quota is not exhausted")
        check(QuotaHUDLevel(remaining: 0) == .exhausted, "HUD exhaustion requires zero remaining")
        check(QuotaHUDLevel(remaining: nil) == nil && QuotaHUDLevel(remaining: .nan) == nil, "unknown values never warn")
        check(hud(89.99).isEmpty, "normal quota has no HUD candidate")
        check(hud(99.8).first?.remainingText == "<1%", "fractional low label never displays fake zero")
        check(hud(95, reset: 1999999999).isEmpty, "expired quota cannot warn")
        check(hud(95, reset: .infinity).isEmpty, "invalid reset cannot warn")
        let low = hud(90)[0], empty = hud(100)[0]
        var hudLedger = QuotaHUDLedger()
        check(hudLedger.shouldPresent(low), "first low reading catches offline consumption")
        hudLedger.markPresented(low, at: at)
        check(!hudLedger.shouldPresent(low), "HUD deduplicates low within cycle")
        check(hudLedger.shouldPresent(empty), "exhaustion still follows a low reminder")
        hudLedger.markPresented(empty, at: at)
        check(!hudLedger.shouldPresent(empty) && !hudLedger.shouldPresent(low), "exhaustion suppresses repeated or corrected low readings")
        let hudData = try JSONEncoder().encode(hudLedger)
        let restoredHUD = try JSONDecoder().decode(QuotaHUDLedger.self, from: hudData)
        check(!restoredHUD.shouldPresent(empty), "HUD dedup survives relaunch")
        check(!String(data: hudData, encoding: .utf8)!.contains("hud-a"), "HUD persistence contains no raw account")
        check(restoredHUD.shouldPresent(hud(90, account: "hud-b")[0]), "HUD accounts remain separate")
        check(restoredHUD.shouldPresent(hud(90, reset: 2000007200)[0]), "HUD permits a new reset cycle")
        let both = hud(95, week: 100)
        check(both.count == 2 && both[0].period == .weekly && both[0].level == .exhausted, "exhaustion wins across periods without merging windows")
        check(hud(100).first?.level == .exhausted, "first exhausted reading skips a misleading low toast")
        let preview = QuotaHUDAlert.preview(.exhausted, at: at)
        hudLedger.markPresented(preview, at: at)
        check(!hudLedger.shouldPresent(preview) && hudLedger.shouldPresent(hud(95, week: 95)[1]), "preview never consumes a real cycle reminder")
        let hook = Data("{\"hook_event_name\":\"PermissionRequest\",\"session_id\":\"approval-test\",\"turn_id\":\"turn-a\",\"cwd\":\"/tmp/test\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"printf hello\",\"description\":\"Review this command\"}}".utf8)
        let permission = try OrbitApprovalRequest.fromHook(hook)
        check(permission.command == "printf hello" && permission.reason == "Review this command", "approval includes exact command and reason")
        check(permission.sessionID == "approval-test" && permission.turnID == "turn-a", "approval retains originating session and turn")
        check(permission.isValid, "new approval has bounded live deadline")
        check((try? OrbitApprovalRequest.fromHook(Data("{}".utf8))) == nil, "unknown hook event defers to original approval")
        check((try? OrbitApprovalRequest.fromHook(Data(repeating: 65, count: 262145))) == nil, "oversized request cannot be approved from truncated content")
        let allow = OrbitApprovalRequest.response(.allow)["hookSpecificOutput"] as? [String: Any]
        check((allow?["decision"] as? [String: Any])?["behavior"] as? String == "allow", "allow uses the official hook response schema")
        check(OrbitApprovalRequest.response(.original).isEmpty, "defer never grants a permission")
        let existingHook = Data("{\"description\":\"keep\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"existing-stop\"}]}],\"PermissionRequest\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"existing-approval\"}]}]}}".utf8)
        let installedHook = try ApprovalHookConfiguration.updating(existingHook, enabled: true)
        let installedText = String(decoding: installedHook, as: UTF8.self)
        check(installedText.contains("existing-stop") && installedText.contains("existing-approval"), "install preserves other hooks and policies")
        let reinstalledHook = try ApprovalHookConfiguration.updating(installedHook, enabled: true)
        check(reinstalledHook == installedHook, "hook installation is idempotent")
        let removedText = String(decoding: try ApprovalHookConfiguration.updating(installedHook, enabled: false), as: UTF8.self)
        check(!removedText.contains("--permission-hook") && removedText.contains("existing-approval"), "removal only removes the Orbit handler")
        check(!installedText.contains("trusted_hash") && !installedText.contains("bypass"), "installer never grants hook trust")
        check((try? ApprovalHookConfiguration.updating(Data("{\"hooks\":false}".utf8), enabled: true)) == nil, "malformed hook config cannot be overwritten")
        print("PASS: \(passed) quota and notification checks")
    }
}
