import Foundation

enum CLILocator {
    static func find(custom: String?) -> URL? {
        let fm = FileManager.default
        if let custom, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: custom).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        var paths: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths += path.split(separator: ":").map { String($0) + "/codex" }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        paths += [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            home + "/Applications/Codex.app/Contents/Resources/codex",
            home + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        ]
        let nvm = URL(fileURLWithPath: home + "/.nvm/versions/node", isDirectory: true)
        if let versions = try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            paths += versions.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }.map { $0.appendingPathComponent("bin/codex").path }
        }
        return paths.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}

@MainActor
final class AppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var connectionTask: Task<Void, Error>?
    private(set) var executableURL: URL?
    private(set) var ready = false
    var onNotification: ((String, Data?) -> Void)?
    var onDisconnect: (() -> Void)?

    func connect(customPath: String?) async throws {
        if ready, process?.isRunning == true { return }
        if let connectionTask { try await connectionTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw OrbitError.disconnected }
            try self.launch(customPath: customPath)
            do {
                _ = try await self.request("initialize", params: ["clientInfo": ["name": "codex_orbit", "title": "Codex Orbit", "version": "0.8.2"]])
                try self.notify("initialized", params: [:])
                self.ready = true
            } catch {
                self.stop()
                throw error
            }
        }
        connectionTask = task
        defer { connectionTask = nil }
        try await task.value
    }

    private func launch(customPath: String?) throws {
        stop()
        guard let executable = CLILocator.find(custom: customPath) else { throw OrbitError.missingCLI }
        executableURL = executable
        let proc = Process()
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        proc.executableURL = executable
        proc.arguments = ["app-server", "--listen", "stdio://"]
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        // This monitor reads the existing ChatGPT sign-in through Codex itself.
        // API keys inherited from a developer shell must not override that sign-in.
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_API_KEY")
        env["PATH"] = executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        proc.environment = env
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        // Never persist raw server logs or authentication material.
        proc.standardError = FileHandle.nullDevice
        let token = UUID()
        generation = token
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if data.isEmpty { self.ended(token: token) } else { self.consume(data) }
            }
        }
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.ended(token: token) }
        }
        do {
            try proc.run()
            process = proc
        } catch {
            stop()
            throw OrbitError.launch(error.localizedDescription)
        }
    }

    func request(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 25) async throws -> Data {
        guard process?.isRunning == true else { throw OrbitError.disconnected }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return }
                guard let self else { return }
                self.timeouts.removeValue(forKey: id)
                self.pending.removeValue(forKey: id)?.resume(throwing: OrbitError.timeout(method))
            }
            do {
                var message: [String: Any] = ["id": id, "method": method]
                if let params { message["params"] = params }
                try send(message)
            } catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String, params: [String: Any]) throws {
        try send(["method": method, "params": params])
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        data.append(10)
        guard let input else { throw OrbitError.disconnected }
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // Guard against corrupt/misconfigured servers without an unbounded memory buffer.
        guard buffer.count < 8_000_000 else { stop(); onDisconnect?(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if let error = message["error"] as? [String: Any] {
                    continuation.resume(throwing: OrbitError.rpc(error["code"] as? Int ?? -1, error["message"] as? String ?? ""))
                } else if let result = message["result"], let encoded = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    continuation.resume(returning: encoded)
                } else { continuation.resume(throwing: OrbitError.malformedResponse) }
            } else if let method = message["method"] as? String {
                // A monitoring client does not support privileged server requests.
                if let id = message["id"] {
                    try? send(["id": id, "error": ["code": -32601, "message": "Read-only quota monitor: method not supported"]])
                    continue
                }
                let params = message["params"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
                onNotification?(method, params)
            }
        }
    }

    private func ended(token: UUID) {
        guard generation == token else { return }
        stop()
        onDisconnect?()
    }

    func stop() {
        generation = UUID()
        ready = false
        output?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        if let proc = process, proc.isRunning {
            proc.terminate()
            let pid = proc.processIdentifier
            // A wedged CLI must not survive after the monitor exits or reconnects.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if proc.isRunning { kill(pid, SIGKILL) }
            }
        }
        input = nil; output = nil; process = nil
        buffer.removeAll(keepingCapacity: true)
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: OrbitError.disconnected) }
    }
}
