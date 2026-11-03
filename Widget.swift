import SwiftUI

@main
struct ContextWidget: App {
    var body: some Scene {
        Window("Контекст чатов Codex", id: "context") {
            TabView {
                ChatList().tabItem { Label("Контекст", systemImage: "bubble.left.and.bubble.right") }
                JobsPage().tabItem { Label("Джобы", systemImage: "clock.arrow.circlepath") }
            }
        }.defaultSize(width: 680, height: 440)
    }
}

private actor Reader {
    var store = UsageStore(directory: ProcessInfo.processInfo.environment["CODEX_HOME"]
        .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
    func read() throws -> [ChatUsage] { try store.read() }
}

@MainActor
private final class Model: ObservableObject {
    let reader = Reader()
    @Published var chats: [ChatUsage] = []
    @Published var message = "Загрузка…"

    func refresh() async {
        while !Task.isCancelled {
            do {
                chats = try await reader.read()
                message = "Нет неархивированных чатов"
            } catch {
                chats = []
                message = "Не удалось прочитать базу чатов Codex"
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

private struct ChatList: View {
    @StateObject private var model = Model()

    var body: some View {
        Table(model.chats) {
            TableColumn("Чат") { chat in
                VStack(alignment: .leading) {
                    Text(chat.title).lineLimit(1)
                    Text(chat.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }.help(chat.title + "\n" + chat.id)
            }
            TableColumn("Потрачено токенов") { chat in
                Text(chat.spent?.formatted() ?? "—").monospacedDigit()
            }.width(140)
            TableColumn("Контекст") { chat in
                Text(chat.percent.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0...2))) } ?? "—")
                    .monospacedDigit()
            }.width(85)
        }
        .overlay { if model.chats.isEmpty { Text(model.message).foregroundStyle(.secondary) } }
        .frame(minWidth: 480, minHeight: 160)
        .task { await model.refresh() }
    }
}
