import Foundation
import SQLite3

struct ChatUsage: Identifiable {
    let id: String
    let title: String
    let spent: Int64?
    let percent: Double?
}

// Read from the tail: large chats can contain hundreds of MB of older turns.
func contextPercent(_ url: URL) -> Double? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard var offset = try? file.seekToEnd() else { return nil }
    var carry = Data()
    let signals = ["token_count", "compacted"].map { Data($0.utf8) }
    while offset > 0 {
        let size = Int(min(offset, 65536))
        offset -= UInt64(size)
        guard (try? file.seek(toOffset: offset)) != nil,
              var block = try? file.read(upToCount: size), block.count == size else { return nil }
        block.append(carry)
        var lines = block.split(separator: 10, omittingEmptySubsequences: false)[...]
        carry = offset > 0 ? Data(lines.removeFirst()) : Data()
        for line in lines.reversed() where signals.contains(where: { line.range(of: $0) != nil }) {
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if event["type"] as? String == "compacted" { return nil }
            guard event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any] else { continue }
            if payload["type"] as? String == "context_compacted" { return nil }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }
            guard let last = info["last_token_usage"] as? [String: Any],
                  let used = last["total_tokens"] as? Int64, used >= 0,
                  let window = info["model_context_window"] as? Int64, window > 0 else { return nil }
            return 100 * Double(used) / Double(window)
        }
    }
    return nil
}

struct UsageStore {
    let directory: URL
    private var cache: [String: (URL, Date, Int, Double?)] = [:]

    init(directory: URL) { self.directory = directory }

    private mutating func percent(_ path: String, id: String) -> Double? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate, let size = values.fileSize else { return nil }
        if let previous = cache[id], previous.0 == url, previous.1 == date, previous.2 == size {
            return previous.3
        }
        let value = contextPercent(url)
        cache[id] = (url, date, size, value)
        return value
    }

    mutating func read() throws -> [ChatUsage] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(directory.appendingPathComponent("state_5.sqlite").path,
                              &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ReadError.database }
        // Keep upstream's user-chat filter and exclude archived chats.
        let query = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), id), tokens_used, rollout_path
            FROM threads WHERE archived = 0 AND (thread_source = 'user' OR
                (thread_source IS NULL AND source IN ('cli', 'vscode', 'appServer')))
            ORDER BY recency_at_ms DESC, id
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { throw ReadError.database }
        func string(_ index: Int32) -> String {
            sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
        }
        var result: [ChatUsage] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let id = string(0)
            let spent = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2)
            result.append(ChatUsage(id: id, title: string(1), spent: spent, percent: percent(string(3), id: id)))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ReadError.database }
        return result.sorted { ($0.percent ?? -1) > ($1.percent ?? -1) }
    }

    enum ReadError: Error { case database }
}
