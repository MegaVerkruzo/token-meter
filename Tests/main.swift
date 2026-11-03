import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let log = temp.appendingPathComponent("rollout.jsonl")
let count = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":9999},"last_token_usage":{"total_tokens":200},"model_context_window":800}}}"#
let compacted = #"{"type":"event_msg","payload":{"type":"context_compacted"}}"#
let heartbeat = #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
func sample(_ lines: [String]) throws -> Double? {
    try lines.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
    return contextPercent(log)
}
check(try sample([count, heartbeat, String(repeating: "x", count: 180000), "{"]) == 25, "Use latest complete usage across blocks")
check(try sample([count, compacted, heartbeat]) == nil, "Clear stale context after compaction")
check(try sample([count, #"{"type":"compacted"}"#]) == nil, "Clear stale context after compacted event")
check(try sample([compacted, count]) == 25, "Read fresh post-compaction usage")
check(try sample([count.replacingOccurrences(of: "800", with: "0")]) == nil, "Missing capacity")
check(try sample([]) == nil, "Empty session")
if CommandLine.arguments.contains("--live") {
    var store = UsageStore(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    let rows = try store.read()
    let id = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"]
    guard let chat = rows.first(where: { $0.id == id }), let pct = chat.percent, let spent = chat.spent else {
        fatalError("Missing current chat telemetry")
    }
    check(rows.map { $0.percent ?? -1 } == rows.map { $0.percent ?? -1 }.sorted(by: >), "Ordering")
    print("Live: \(rows.count) chats, current chat \(spent) tokens and \(pct)%")
}
print("OK")
