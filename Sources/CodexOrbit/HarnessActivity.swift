import Foundation
import CryptoKit

enum HarnessPhase: String, Codable {
    case unknown, idle, working, waiting
    var description: String {
        switch self {
        case .unknown: return "工作状态待同步"
        case .idle: return "Codex 空闲"
        case .working: return "Codex 思考 / 执行中"
        case .waiting: return "Codex 等待授权"
        }
    }
}

struct HarnessActivityEvent: Codable, Equatable {
    enum Kind: String, Codable { case start, heartbeat, stop, interrupt, end }
    let messageType: String
    let sessionHash: String
    let turnID: String?
    let kind: Kind
    let timestamp: Date

    static func hashSession(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func fromHook(_ data: Data, at now: Date = Date()) throws -> HarnessActivityEvent {
        guard data.count <= 262_144,
              let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = input["session_id"] as? String, !session.isEmpty,
              let name = input["hook_event_name"] as? String else { throw CocoaError(.coderInvalidValue) }
        let kind: Kind
        switch name {
        case "UserPromptSubmit": kind = .start
        case "PreToolUse": kind = .heartbeat
        case "Stop": kind = .stop
        case "Interrupt": kind = .interrupt
        case "SessionEnd": kind = .end
        default: throw CocoaError(.coderInvalidValue)
        }
        // Deliberately exclude prompt, tool input, transcript path, cwd and assistant messages.
        return HarnessActivityEvent(messageType: "activity", sessionHash: hashSession(session),
                                    turnID: input["turn_id"] as? String, kind: kind, timestamp: now)
    }
    func isValid(at now: Date) -> Bool {
        messageType == "activity" && sessionHash.count == 64 && sessionHash.allSatisfy { $0.isHexDigit } &&
        (turnID?.utf8.count ?? 0) <= 256 && timestamp <= now.addingTimeInterval(5) && timestamp > now.addingTimeInterval(-30)
    }
}

struct HarnessActivityLedger {
    private struct Record {
        var turnID: String?
        var working: Bool
        var updatedAt: Date
        var closedTurns: [String]
    }
    private var sessions: [String: Record] = [:]
    static let staleAfter: TimeInterval = 600

    mutating func receive(_ event: HarnessActivityEvent, at now: Date) {
        guard event.isValid(at: now) else { return }
        var record = sessions[event.sessionHash] ?? Record(turnID: nil, working: false, updatedAt: .distantPast, closedTurns: [])
        guard event.timestamp > record.updatedAt else { return }
        switch event.kind {
        case .start:
            if let turn = event.turnID, record.closedTurns.contains(turn) { return }
            record.turnID = event.turnID; record.working = true
        case .heartbeat:
            if let turn = event.turnID {
                if record.closedTurns.contains(turn) { return }
                if record.working, let current = record.turnID, current != turn { return }
                record.turnID = turn
            } else if !record.working && record.updatedAt != .distantPast { return }
            record.working = true
        case .stop, .interrupt, .end:
            if event.kind != .end, let turn = event.turnID, let current = record.turnID, turn != current { return }
            if let turn = event.turnID ?? record.turnID {
                record.closedTurns.append(turn)
                record.closedTurns = Array(record.closedTurns.suffix(8))
            }
            record.working = false
        }
        record.updatedAt = event.timestamp
        sessions[event.sessionHash] = record
        if sessions.count > 256 {
            sessions = Dictionary(uniqueKeysWithValues: sessions.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(256).map { ($0.key, $0.value) })
        }
    }

    func phase(at now: Date, waitingSessions: Set<String> = []) -> HarnessPhase {
        let busy = sessions.filter { $0.value.working && !waitingSessions.contains($0.key) }
        if busy.contains(where: { now.timeIntervalSince($0.value.updatedAt) <= Self.staleAfter }) { return .working }
        if !waitingSessions.isEmpty { return .waiting }
        if !busy.isEmpty { return .unknown }
        return sessions.isEmpty ? .unknown : .idle
    }
    mutating func reset() { sessions.removeAll() }
}

enum HarnessActivityHookConfiguration {
    static let command = "'/Applications/Codex Orbit.app/Contents/MacOS/CodexOrbit' --activity-hook"
    static let events = ["UserPromptSubmit", "PreToolUse", "Stop", "Interrupt", "SessionEnd"]

    static func updating(_ data: Data?) throws -> Data {
        var config: [String: Any] = [:]
        if let data {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
            config = value
        }
        guard config["hooks"] == nil || config["hooks"] is [String: Any] else { throw CocoaError(.coderInvalidValue) }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        for event in events {
            guard hooks[event] == nil || hooks[event] is [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
            var groups = hooks[event] as? [[String: Any]] ?? []
            guard groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else { throw CocoaError(.coderInvalidValue) }
            // Retain positions of existing handlers, preserving their trust keys and hashes.
            if !groups.contains(where: { group in (group["hooks"] as? [[String: Any]] ?? []).contains(where: { $0["command"] as? String == command }) }) {
                groups.append(["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 3]]])
            }
            hooks[event] = groups
        }
        config["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
