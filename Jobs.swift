import Foundation
import Darwin

struct JobEvent: Decodable {
    let time: Double
    let phase: String
    let stage: Int
    let detail: String
    let scheduled: Double?
}

struct Handoff: Decodable {
    let stage: Int
    let next_stage: Int
    let revision: String
    let evidence: [String: String]
}

struct JobJournal: Decodable {
    let ticket: String
    let stage: Int
    let transitions: [Handoff]
}

struct Activity: Decodable {
    let ticket: String
    let host: String
    let events: [JobEvent]
}

struct JobSchedule: Decodable {
    let interval: Int
    let next: Double?
    let host: String
}

struct TicketJob: Identifiable {
    let id: String
    let journal: JobJournal?
    let activity: Activity?
    let schedules: [JobSchedule]
    let busy: Bool?
    let errors: [String]

    var stage: Int? { journal?.stage ?? activity?.events.last?.stage }

    var status: String {
        guard let event = activity?.events.last else { return journal == nil ? "Нет сведений о ходе работы" : "Последнее состояние из журнала" }
        if ["observing", "dispatching"].contains(event.phase) && busy == false {
            return "Попытка прервалась"
        }
        return Self.label(event.phase)
    }

    static func label(_ phase: String) -> String {
        switch phase {
        case "observing": return "Проверка условий"
        case "dispatching": return "Передача следующей джобе"
        case "waiting": return "Ожидание условия"
        case "entered": return "Переход выполнен"
        case "stopped": return "Достигнут заданный этап"
        case "error": return "Ошибка запуска"
        default: return phase
        }
    }
}

struct JobsStore {
    let root: URL
    private let fs = FileManager.default

    // Shared nonblocking flock checks the kernel lease held by the Python runner.
    // A leftover file after a crash must never advertise a live timer.
    private func locked(_ path: URL) -> Bool? {
        let fd = open(path.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK ? true : nil
    }

    private func read<T: Decodable>(_ type: T.Type, _ path: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: path))
    }

    func load() throws -> [TicketJob] {
        let dirs: [URL]
        do {
            dirs = try fs.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: .skipsHiddenFiles)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try dirs.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map(loadTicket).sorted { $0.id < $1.id }
    }

    private func loadTicket(_ dir: URL) -> TicketJob {
        var errors: [String] = []
        func optional<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
            do { return try read(type, dir.appendingPathComponent(name)) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            catch { errors.append("Не удалось прочитать " + name); return nil }
        }
        let journal = optional(JobJournal.self, "journal.json")
        let activity = optional(Activity.self, "activity.json")
        var schedules: [JobSchedule] = []
        do {
            for timer in try fs.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                where timer.lastPathComponent.hasPrefix("timer-") {
                if locked(timer.appendingPathComponent("lease")) == true,
                   let schedule = try? read(JobSchedule.self, timer.appendingPathComponent("schedule.json")) {
                    schedules.append(schedule)
                }
            }
        } catch { errors.append("Не удалось прочитать расписание") }
        return TicketJob(id: dir.lastPathComponent, journal: journal, activity: activity,
                         schedules: schedules, busy: locked(dir.appendingPathComponent("lock")), errors: errors)
    }
}
