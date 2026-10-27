import Foundation
import SQLite3

enum LocalSessionTokens {
    static func read(ids: [String], home: URL? = nil) -> [String: Int64] {
        guard !ids.isEmpty, ids.count <= 16 else { return [:] }
        let directory = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("state") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        for file in files {
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 80)
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = "SELECT id, tokens_used FROM threads WHERE id IN (\(placeholders))"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, id) in ids.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), id, -1, transient) }
            var result: [String: Int64] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let key = sqlite3_column_text(statement, 0), sqlite3_column_type(statement, 1) == SQLITE_INTEGER else { continue }
                let value = sqlite3_column_int64(statement, 1)
                // Zero is also the metadata DB's unknown/default value, so don't invent a measured zero.
                if value > 0 { result[String(cString: key)] = value }
            }
            return result
        }
        return [:]
    }
}
