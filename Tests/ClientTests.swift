import Foundation

@main
@MainActor
struct ClientTests {
    static func main() async throws {
        let path = CommandLine.arguments[1]
        let client = AppServerClient()
        var notifications = 0
        client.onNotification = { method, _ in if method == "test/notification" { notifications += 1 } }
        try await client.connect(customPath: path)
        guard client.ready else { fatalError("Handshake failed") }
        let chunk = try await client.request("test/chunks")
        let decoded = try JSONSerialization.jsonObject(with: chunk) as! [String: Any]
        guard decoded["unicode"] as? String == "薄荷圆环", decoded["number"] as? Int == 7 else { fatalError("Fragmented UTF-8 response corrupted") }
        guard notifications == 1 else { fatalError("Notification was lost") }
        do {
            _ = try await client.request("test/error")
            fatalError("Server error was ignored")
        } catch OrbitError.rpc(let code, _) {
            guard code == -32001 else { fatalError("Wrong RPC error") }
        }
        do {
            _ = try await client.request("test/timeout", timeout: 0.15)
            fatalError("Request never timed out")
        } catch OrbitError.timeout { }
        let echo = try await client.request("test/echo", params: ["afterTimeout": true])
        guard (try JSONSerialization.jsonObject(with: echo) as? [String: Bool])?["afterTimeout"] == true else { fatalError("Timeout poisoned the next request") }
        do {
            _ = try await client.request("test/exit")
            fatalError("Disconnect was ignored")
        } catch OrbitError.disconnected { }
        try await client.connect(customPath: path)
        guard client.ready else { fatalError("Reconnect failed") }
        client.stop()
        guard !client.ready else { fatalError("Stopped client remains ready") }
        guard CLILocator.find(custom: "/not/an/executable") == nil else { fatalError("Invalid explicit path silently fell back") }
        print("PASS: handshake, fragmented UTF-8, notifications, server errors, timeout recovery, exit, reconnect, shutdown, CLI selection")
    }
}
