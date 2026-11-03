import SwiftUI

private actor JobsReader {
    let store = JobsStore(root: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/harness/ticket-lifecycle"))
    func read() throws -> [TicketJob] { try store.load() }
}

private func timestamp(_ seconds: Double) -> String {
    Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .standard)
}

@MainActor
private final class JobsModel: ObservableObject {
    private let reader = JobsReader()
    @Published var jobs: [TicketJob] = []
    @Published var selected: String?
    @Published var checked: Date?
    @Published var error = ""

    func refresh() async {
        while !Task.isCancelled {
            do {
                jobs = try await reader.read()
                if !jobs.contains(where: { $0.id == selected }) { selected = jobs.first?.id }
                checked = Date()
                error = ""
            } catch { self.error = "Не удалось прочитать каталог запусков" }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

struct JobsPage: View {
    @StateObject private var model = JobsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Джобы harness").font(.headline)
                Spacer()
                if let checked = model.checked {
                    Text("Обновлено " + checked.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                }
            }.padding(.horizontal)
            if !model.error.isEmpty {
                Text(model.error).foregroundStyle(.red).padding()
            } else if model.jobs.isEmpty {
                Text(model.checked == nil ? "Загрузка…" : "Пока нет локальных запусков").padding()
            } else {
                HSplitView {
                    List(model.jobs, selection: $model.selected) { job in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.id).font(.headline)
                            Text(job.status).font(.caption).foregroundStyle(.secondary)
                        }.tag(job.id)
                    }.frame(minWidth: 155, idealWidth: 185)
                    ScrollView {
                        if let job = model.jobs.first(where: { $0.id == model.selected }) {
                            JobDetails(job: job)
                        }
                    }.frame(minWidth: 280, maxWidth: .infinity)
                }
            }
            Spacer(minLength: 0)
        }.padding(.top, 8)
        .task { await model.refresh() }
    }
}

private struct JobDetails: View {
    let job: TicketJob
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(job.id).font(.title3.bold()).textSelection(.enabled)
            if let stage = job.stage {
                Text("Этап " + String(stage) + " из 4 · " + ([1: "Исследование", 2: "Реализация", 3: "Ревью", 4: "Закрытие"][stage] ?? "Неизвестен"))
            }
            Text(job.status)
            if let host = job.activity?.host { Text("Исполнитель · " + host) }
            if let last = job.activity?.events.last {
                Text("С " + timestamp(last.time)).foregroundStyle(.secondary)
                if !last.detail.isEmpty { Text(last.detail).textSelection(.enabled) }
            }
            Divider()
            Text("Расписание").font(.headline)
            if job.schedules.isEmpty { Text("Активного таймера harness нет") }
            ForEach(job.schedules.indices, id: \.self) { i in
                let schedule = job.schedules[i]
                Text("Интервал " + String(schedule.interval) + " с · " + schedule.host)
                if let due = schedule.next {
                    let late = Int(Date().timeIntervalSince1970 - due)
                    Text("Следующий запуск · " + timestamp(due))
                    if late > 2 { Text("Просрочен на " + String(late) + " с").foregroundStyle(.orange) }
                } else { Text("Текущий запуск выполняется") }
            }
            ForEach(job.errors, id: \.self) { Text($0).foregroundStyle(.red) }
            if let items = job.journal?.transitions, !items.isEmpty {
                Divider()
                Text("Подтверждённые переходы").font(.headline)
                ForEach(items.indices.reversed(), id: \.self) { i in
                    let item = items[i]
                    Text("Этап " + String(item.stage) + " → " + String(item.next_stage) + " · " + String(item.revision.prefix(10)))
                        .textSelection(.enabled)
                    HStack {
                        ForEach(["primary_pr", "design", "required_checks_started"], id: \.self) { key in
                            if let raw = item.evidence[key], let url = URL(string: raw),
                               url.scheme == "https", url.host != nil {
                                Link(["primary_pr": "PR", "design": "Дизайн", "required_checks_started": "CI"][key]!, destination: url)
                            }
                        }
                    }
                }
            }
            if let log = job.activity, !log.events.isEmpty {
                Divider()
                Text("Последние действия").font(.headline)
                ForEach(log.events.indices.reversed(), id: \.self) { i in
                    let event = log.events[i]
                    VStack(alignment: .leading) {
                        Text(timestamp(event.time) + " · " + TicketJob.label(event.phase))
                        if let due = event.scheduled { Text("По плану · " + timestamp(due)).foregroundStyle(.secondary) }
                        if !event.detail.isEmpty { Text(event.detail).foregroundStyle(.secondary) }
                    }.font(.caption)
                }
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
    }
}
