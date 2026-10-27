import Foundation
import Combine
import Darwin

private final class ApprovalChannel {
    let fd: Int32
    private let lock = NSLock()
    private var finished = false
    init(_ fd: Int32) { self.fd = fd }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func reply(id: UUID, decision: OrbitApprovalDecision) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let data = try? JSONSerialization.data(withJSONObject: ["id": id.uuidString, "decision": decision.rawValue]) {
            try? ApprovalSocket.send(data, to: fd)
        }
        shutdown(fd, SHUT_RDWR)
    }
}

@MainActor
final class ApprovalBridge: ObservableObject {
    @Published private(set) var requests: [OrbitApprovalRequest] = []
    @Published private(set) var status = "等待 Codex 授权请求；新增 Hook 需先在 Codex 中信任。"
    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "approvalBridgeEnabled")
            if !enabled { releaseAll() }
        }
    }
    private var channels: [UUID: ApprovalChannel] = [:]
    private var listener: Int32 = -1
    private var listeningPath: String?
    var isListening: Bool { listener >= 0 }
    var onActivity: ((HarnessActivityEvent) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "approvalBridgeEnabled") as? Bool ?? true
    }

    func start(path: String = ApprovalSocket.path) {
        guard listener < 0 else { return }
        do {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
            guard attributes[.ownerAccountID] as? UInt32 == getuid(),
                  (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0 else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: path) {
                if let existing = try? ApprovalSocket.connect(path: path) {
                    Darwin.close(existing); status = "另一个 Codex Orbit 正在接收授权。"; return
                }
                let item = try FileManager.default.attributesOfItem(atPath: path)
                guard item[.type] as? FileAttributeType == .typeSocket, item[.ownerAccountID] as? UInt32 == getuid() else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(atPath: path)
            }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            var address = try ApprovalSocket.address(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
                Darwin.close(fd); throw CocoaError(.fileWriteUnknown)
            }
            listener = fd; listeningPath = path
            let capacity = DispatchSemaphore(value: 16)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while true {
                    let peer = accept(fd, nil, nil)
                    guard peer >= 0 else { break }
                    guard ApprovalSocket.sameUser(peer), capacity.wait(timeout: .now()) == .success else { Darwin.close(peer); continue }
                    ApprovalSocket.configure(peer)
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        defer { Darwin.close(peer); capacity.signal() }
                        guard let data = try? ApprovalSocket.receive(from: peer, timeout: 2) else { return }
                        if let event = try? JSONDecoder().decode(HarnessActivityEvent.self, from: data), event.isValid(at: Date()) {
                            Task { @MainActor [weak self] in self?.onActivity?(event) }
                            try? ApprovalSocket.send(Data("{}".utf8), to: peer)
                            return
                        }
                        guard let request = try? JSONDecoder().decode(OrbitApprovalRequest.self, from: data), request.isValid else { return }
                        let channel = ApprovalChannel(peer)
                        Task { @MainActor [weak self] in self?.enqueue(request, channel: channel) }
                        while !channel.isFinished && request.deadline.timeIntervalSinceNow > 0 {
                            var descriptor = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
                            if poll(&descriptor, 1, 250) > 0 { break }
                        }
                        channel.reply(id: request.id, decision: .original)
                        Task { @MainActor [weak self] in self?.remove(request.id) }
                    }
                }
            }
        } catch { status = "授权联动未连接，请重新启动 Codex Orbit。" }
    }

    private func enqueue(_ request: OrbitApprovalRequest, channel: ApprovalChannel) {
        guard enabled, request.isValid, !channel.isFinished, requests.count < 8, channels[request.id] == nil else {
            channel.reply(id: request.id, decision: .original); return
        }
        channels[request.id] = channel
        requests.append(request)
        status = "已接收到 Codex 的真实授权请求。"
    }

    func decide(_ request: OrbitApprovalRequest, _ decision: OrbitApprovalDecision) {
        guard let channel = channels[request.id], !channel.isFinished else { return }
        channel.reply(id: request.id, decision: request.deadline > Date() ? decision : .original)
        remove(request.id)
    }

    private func remove(_ id: UUID) {
        channels.removeValue(forKey: id)
        requests.removeAll { $0.id == id }
    }

    func releaseAll() {
        for request in requests { channels[request.id]?.reply(id: request.id, decision: .original) }
        channels.removeAll(); requests.removeAll()
    }

    func stop() {
        releaseAll()
        if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 }
        if let path = listeningPath { try? FileManager.default.removeItem(atPath: path) }
        listeningPath = nil
    }

    func installHook() {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("hooks.json")
            let old = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            let updated = try ApprovalHookConfiguration.updating(old, enabled: true)
            if let old, old != updated {
                let backup = directory.appendingPathComponent("hooks.before-codex-orbit-\(Int(Date().timeIntervalSince1970)).json")
                try old.write(to: backup, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
            try updated.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            enabled = true
            status = "Hook 已安装。请在 Codex 的 /hooks 中信任 Codex Orbit，再重开会话。"
        } catch { status = "Hook 安装失败，原有配置已保留。请检查 ~/.codex/hooks.json。" }
    }
}
