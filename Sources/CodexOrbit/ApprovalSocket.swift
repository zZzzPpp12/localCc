import Foundation
import Darwin

enum ApprovalSocket {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Orbit", isDirectory: true)
    static let path = directory.appendingPathComponent("approval.sock").path

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileWriteInvalidFileName) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: path.utf8)
        }
        return address
    }

    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func connect(path: String = path) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        configure(fd)
        var address = try address(path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, sameUser(fd) else { Darwin.close(fd); throw CocoaError(.fileReadNoPermission) }
        return fd
    }

    static func send(_ data: Data, to fd: Int32) throws {
        var bytes = data; bytes.append(10)
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                sent += count
            }
        }
    }

    static func receive(from fd: Int32, timeout: TimeInterval, limit: Int = 300_000) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let milliseconds = Int32(max(1, min(1000, deadline.timeIntervalSinceNow * 1000)))
            let ready = poll(&descriptor, 1, milliseconds)
            if ready == 0 { continue }
            guard ready > 0 else { throw CocoaError(.fileReadUnknown) }
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
            if let newline = data.firstIndex(of: 10) { return data.prefix(upTo: newline) }
        }
        throw CocoaError(.userCancelled)
    }

    static func runHook() {
        // Hook stdout is the official decision JSON. Any failure defers to Codex's normal prompt.
        var response: [String: Any] = [:]
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 262_144 else { throw CocoaError(.fileReadTooLarge) }
            }
            let request = try OrbitApprovalRequest.fromHook(data)
            let fd = try connect()
            defer { Darwin.close(fd) }
            try send(JSONEncoder().encode(request), to: fd)
            let reply = try receive(from: fd, timeout: 120, limit: 4096)
            if let value = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
               value["id"] as? String == request.id.uuidString,
               let raw = value["decision"] as? String, let decision = OrbitApprovalDecision(rawValue: raw) {
                response = OrbitApprovalRequest.response(decision)
            }
        } catch { }
        let output = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(output + Data([10]))
    }

    static func runActivityHook() {
        // Observational only: no prompt/context output, permission decision, or task execution.
        defer { FileHandle.standardOutput.write(Data("{}\n".utf8)) }
        do {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 262_144 else { return }
            }
            let event = try HarnessActivityEvent.fromHook(data)
            let fd = try connect()
            defer { Darwin.close(fd) }
            try send(JSONEncoder().encode(event), to: fd)
            _ = try? receive(from: fd, timeout: 0.35, limit: 256)
        } catch { }
    }
}
