import Foundation

enum OrbitApprovalDecision: String { case allow, deny, original }

struct OrbitApprovalRequest: Codable, Equatable, Identifiable {
    let id: UUID
    let sessionID: String
    let turnID: String?
    let cwd: String
    let toolName: String
    let inputJSON: String
    let reason: String?
    let deadline: Date

    static func fromHook(_ data: Data, now: Date = Date()) throws -> OrbitApprovalRequest {
        guard data.count <= 262_144,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["hook_event_name"] as? String == "PermissionRequest",
              let session = value["session_id"] as? String, !session.isEmpty,
              let tool = value["tool_name"] as? String, !tool.isEmpty,
              let input = value["tool_input"], JSONSerialization.isValidJSONObject(input) else {
            throw CocoaError(.coderInvalidValue)
        }
        let encoded = try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return OrbitApprovalRequest(id: UUID(), sessionID: session, turnID: value["turn_id"] as? String,
                                    cwd: value["cwd"] as? String ?? "工作目录未知", toolName: tool,
                                    inputJSON: String(decoding: encoded, as: UTF8.self),
                                    reason: (input as? [String: Any])?["description"] as? String,
                                    deadline: now.addingTimeInterval(120))
    }

    var isValid: Bool {
        !sessionID.isEmpty && !toolName.isEmpty && inputJSON.utf8.count <= 262_144 &&
        deadline.timeIntervalSinceNow > 0 && deadline.timeIntervalSinceNow <= 125
    }
    var title: String {
        if toolName == "Bash" { return "运行命令" }
        if toolName == "apply_patch" { return "修改文件" }
        return toolName.hasPrefix("mcp__") ? "调用 MCP 工具" : toolName
    }
    var command: String? {
        guard let data = inputJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["command"] as? String
    }

    static func response(_ decision: OrbitApprovalDecision) -> [String: Any] {
        if decision == .original { return [:] }
        var result: [String: Any] = ["behavior": decision.rawValue]
        if decision == .deny { result["message"] = "用户在 Codex Orbit 中拒绝了本次操作。" }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
    }
}

enum ApprovalHookConfiguration {
    static let command = "'/Applications/Codex Orbit.app/Contents/MacOS/CodexOrbit' --permission-hook"

    static func updating(_ data: Data?, enabled: Bool) throws -> Data {
        var config: [String: Any] = [:]
        if let data {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.coderInvalidValue) }
            config = decoded
        }
        guard config["hooks"] == nil || config["hooks"] is [String: Any] else { throw CocoaError(.coderInvalidValue) }
        var hooks = config["hooks"] as? [String: Any] ?? [:]
        guard hooks["PermissionRequest"] == nil || hooks["PermissionRequest"] is [[String: Any]] else { throw CocoaError(.coderInvalidValue) }
        var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        guard groups.allSatisfy({ $0["hooks"] is [[String: Any]] }) else { throw CocoaError(.coderInvalidValue) }
        groups = groups.compactMap { group in
            var copy = group
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { $0["command"] as? String != command }
            guard !handlers.isEmpty else { return nil }
            copy["hooks"] = handlers; return copy
        }
        if enabled {
            groups.append(["matcher": "*", "hooks": [["type": "command", "command": command,
                                                        "timeout": 125, "statusMessage": "等待 Codex Orbit 中的授权确认"]]])
        }
        hooks["PermissionRequest"] = groups
        config["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}
