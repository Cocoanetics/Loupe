import SwiftUI

@main
struct TaskDemoApp: App {
    @StateObject private var store = TaskStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

/// One task. `id` doubles as the accessibility identifier, which is what makes
/// the list addressable from a script without depending on the visible title.
struct TaskItem: Identifiable, Hashable {
    let id: String
    var title: String
    var notes: String
    var isDone: Bool
    var priority: Int
}

@MainActor
final class TaskStore: ObservableObject {
    @Published var tasks: [TaskItem]

    init() {
        tasks = (1...12).map {
            TaskItem(
                id: "task-\($0)",
                title: "Task \($0)",
                notes: "Notes for task \($0)",
                isDone: $0 % 4 == 0,
                priority: $0 % 3)
        }
    }

    func add(title: String) {
        let next = tasks.count + 1
        tasks.insert(
            TaskItem(id: "task-\(next)", title: title, notes: "", isDone: false, priority: 1),
            at: 0)
    }

    func toggle(_ id: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].isDone.toggle()
    }
}
