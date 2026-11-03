import Foundation
import Darwin

let fs = FileManager.default
let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fs.removeItem(at: root) }
let store = JobsStore(root: root)
let missing = try store.load()
precondition(missing.isEmpty)
let dir = root.appendingPathComponent("DEMO-1")
let timer = dir.appendingPathComponent("timer-test")
try fs.createDirectory(at: timer, withIntermediateDirectories: true)
func write(_ name: String, _ json: String) throws {
    try Data(json.utf8).write(to: dir.appendingPathComponent(name))
}
try write("journal.json", #"{"ticket":"DEMO-1","stage":3,"transitions":[]}"#)
let legacy = try store.load()[0]
precondition(legacy.stage == 3 && legacy.activity == nil && legacy.errors.isEmpty)
try write("activity.json", #"{"ticket":"DEMO-1","host":"local","events":[{"stage":2,"phase":"observing","time":100,"detail":""}]}"#)
try write("timer-test/schedule.json", #"{"interval":30,"next":120,"host":"local"}"#)
try write("timer-test/lease", "")
try write("lock", "")
let fd = open(timer.appendingPathComponent("lease").path, O_RDWR)
precondition(fd >= 0 && flock(fd, LOCK_EX) == 0)
let active = try store.load()[0]
precondition(active.schedules.first?.next == 120)
precondition(active.status == "Попытка прервалась")
close(fd)
let dead = try store.load()[0]
precondition(dead.schedules.isEmpty)
try write("activity.json", "{")
let broken = try store.load()[0]
precondition(!broken.errors.isEmpty && broken.stage == 3)
if CommandLine.arguments.count == 2 {
    let live = try JobsStore(root: URL(fileURLWithPath: CommandLine.arguments[1])).load()
    for job in live {
        print(job.id, job.stage ?? 0, job.status, "timers", job.schedules.count, "handoffs", job.journal?.transitions.count ?? 0)
    }
}
print("OK")
