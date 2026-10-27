import Foundation

@main
struct ActivityTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: \(label)") }
        count += 1
    }
    static func main() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func event(_ name: String, _ offset: Double, session: String = "s1", turn: String = "t1") throws -> HarnessActivityEvent {
            let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": session, "turn_id": turn,
                                                                   "prompt": "PRIVATE_PROMPT", "tool_input": ["command": "PRIVATE_COMMAND"],
                                                                   "transcript_path": "/private/transcript"])
            return try HarnessActivityEvent.fromHook(data, at: now.addingTimeInterval(offset))
        }
        let start = try event("UserPromptSubmit", 0)
        let wire = String(decoding: try JSONEncoder().encode(start), as: UTF8.self)
        check(!wire.contains("PRIVATE") && !wire.contains("transcript") && !wire.contains("s1"), "wire contains no prompt, command, transcript or raw session ID")
        check(start.isValid(at: now), "valid lifecycle event accepted")
        check(!start.isValid(at: now.addingTimeInterval(31)), "old replayed event rejected")
        check(!start.isValid(at: now.addingTimeInterval(-6)), "future event rejected")
        check((try? HarnessActivityEvent.fromHook(Data("{}".utf8))) == nil, "missing session does not imply work")
        check((try? event("PermissionRequest", 0)) == nil, "activity endpoint cannot parse an approval event")
        var ledger = HarnessActivityLedger()
        check(ledger.phase(at: now) == .unknown, "cold start is unknown")
        ledger.receive(start, at: now)
        check(ledger.phase(at: now) == .working, "prompt begins work")
        let waiting: Set<String> = [start.sessionHash]
        check(ledger.phase(at: now, waitingSessions: waiting) == .waiting, "approval wait suspends thinking")
        let other = try event("UserPromptSubmit", 1, session: "s2", turn: "t2")
        ledger.receive(other, at: other.timestamp)
        check(ledger.phase(at: other.timestamp, waitingSessions: waiting) == .working, "another running session keeps harness busy")
        let stopped = try event("Stop", 2)
        ledger.receive(stopped, at: stopped.timestamp)
        check(ledger.phase(at: stopped.timestamp) == .working, "stopping one session cannot stop another")
        let interrupted = try event("Interrupt", 3, session: "s2", turn: "t2")
        ledger.receive(interrupted, at: interrupted.timestamp)
        check(ledger.phase(at: interrupted.timestamp) == .idle, "all stopped sessions return idle")
        let late = try event("PreToolUse", 4)
        ledger.receive(late, at: late.timestamp)
        check(ledger.phase(at: late.timestamp) == .idle, "late tool event cannot revive a completed turn")
        let next = try event("UserPromptSubmit", 5, turn: "t-next")
        ledger.receive(next, at: next.timestamp)
        let lateStop = try event("Stop", 6)
        ledger.receive(lateStop, at: lateStop.timestamp)
        check(ledger.phase(at: lateStop.timestamp) == .working, "old turn stop cannot stop newer turn")
        check(ledger.phase(at: now.addingTimeInterval(606)) == .unknown, "lost stop / crashed client cannot animate forever")
        let heartbeat = try event("PreToolUse", 607, turn: "t-next")
        ledger.receive(heartbeat, at: heartbeat.timestamp)
        check(ledger.phase(at: heartbeat.timestamp) == .working, "fresh heartbeat restores live state")
        let ended = try event("SessionEnd", 608, turn: "t-next")
        ledger.receive(ended, at: ended.timestamp)
        check(ledger.phase(at: ended.timestamp) == .idle, "session end stops thinking")
        ledger.reset()
        check(ledger.phase(at: ended.timestamp) == .unknown, "restart forgets unverified work state")
        let firstTool = try event("PreToolUse", 609)
        ledger.receive(firstTool, at: firstTool.timestamp)
        check(ledger.phase(at: firstTool.timestamp) == .working, "first tool can establish state if monitor starts mid-turn")
        let original = Data("{\"hooks\":{\"PermissionRequest\":[{\"hooks\":[{\"command\":\"keep-permission\",\"type\":\"command\"}]}],\"Stop\":[{\"hooks\":[{\"command\":\"keep-stop\",\"type\":\"command\"}]}]}}".utf8)
        let merged = try HarnessActivityHookConfiguration.updating(original)
        let again = try HarnessActivityHookConfiguration.updating(merged)
        check(merged == again, "lifecycle hook installation is idempotent")
        let before = try JSONSerialization.jsonObject(with: original) as! NSDictionary
        let after = try JSONSerialization.jsonObject(with: merged) as! NSDictionary
        let beforeHooks = before["hooks"] as! NSDictionary, afterHooks = after["hooks"] as! NSDictionary
        check((beforeHooks["PermissionRequest"] as! NSArray) == (afterHooks["PermissionRequest"] as! NSArray), "approval hook and trust key unchanged")
        check(((afterHooks["Stop"] as! [[String: Any]])[0]["hooks"] as! NSArray) == ((beforeHooks["Stop"] as! [[String: Any]])[0]["hooks"] as! NSArray), "old hook order and definitions unchanged")
        let text = String(decoding: merged, as: UTF8.self)
        check(!text.contains("trusted_hash") && !text.contains("bypass"), "installer cannot grant trust")
        check(HarnessActivityHookConfiguration.events.allSatisfy { afterHooks[$0] != nil }, "all required lifecycle events installed")
        check((try? HarnessActivityHookConfiguration.updating(Data("{\"hooks\":false}".utf8))) == nil, "bad config is not overwritten")
        print("PASS: \(count) harness lifecycle, privacy and hook preservation checks")
    }
}
