import Foundation
import Combine

@MainActor
final class HarnessActivityStore: ObservableObject {
    @Published private(set) var phase: HarnessPhase = .unknown
    @Published private(set) var animationActive = false
    @Published private(set) var hookStatus = "工作状态 Hook 需先在 Codex 中信任。"
    private var ledger = HarnessActivityLedger()
    private var waiting = Set<String>()
    private var awake = true
    private var visible = true

    func receive(_ event: HarnessActivityEvent, at now: Date = Date()) {
        guard event.isValid(at: now) else { return }
        ledger.receive(event, at: now)
        if hookStatus != "已接收到 Codex 本机工作状态事件。" { hookStatus = "已接收到 Codex 本机工作状态事件。" }
        tick(at: now)
    }
    func update(waitingRequests: [OrbitApprovalRequest], awake: Bool, visible: Bool, at now: Date = Date()) {
        waiting = Set(waitingRequests.map { HarnessActivityEvent.hashSession($0.sessionID) })
        self.awake = awake; self.visible = visible
        tick(at: now)
    }
    func tick(at now: Date = Date()) {
        let value = ledger.phase(at: now, waitingSessions: waiting)
        if phase != value { phase = value }
        let animated = value == .working && awake && visible
        if animationActive != animated { animationActive = animated }
    }
    func reset() { ledger.reset(); tick() }

    func installHooks() {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("hooks.json")
            let old = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
            let data = try HarnessActivityHookConfiguration.updating(old)
            if let old, data != old {
                let backup = directory.appendingPathComponent("hooks.before-codex-orbit-activity-\(Int(Date().timeIntervalSince1970)).json")
                try old.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            hookStatus = "状态 Hook 已安装；请在 Codex /hooks 中信任新增的 --activity-hook 项。"
        } catch { hookStatus = "状态 Hook 安装失败，请检查配置文件。" }
    }
}
