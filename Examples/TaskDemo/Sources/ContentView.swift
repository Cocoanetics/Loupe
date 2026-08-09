import SwiftUI

/// A sidebar-plus-detail layout, which SwiftUI presents very differently by
/// device: a persistent two-column split on iPad, a push-navigation stack on
/// iPhone. That difference is the point — it is what a script has to cope with,
/// and what makes "run the same flow on both" a real test rather than a
/// formality.
struct ContentView: View {
    @EnvironmentObject private var store: TaskStore
    @State private var selection: TaskItem?
    @State private var showingAdd = false
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable {
        case all = "All"
        case open = "Open"
        case done = "Done"
    }

    private var visible: [TaskItem] {
        switch filter {
            case .all: return store.tasks
            case .open: return store.tasks.filter { !$0.isDone }
            case .done: return store.tasks.filter(\.isDone)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Picker("Filter", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("filter")
                }

                Section("Tasks") {
                    ForEach(visible) { task in
                        NavigationLink(value: task) {
                            TaskRow(task: task)
                        }
                        .accessibilityIdentifier(task.id)
                    }
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-task")
                }
            }
            .navigationDestination(for: TaskItem.self) { task in
                DetailView(task: task)
            }
        } detail: {
            if let selection {
                DetailView(task: selection)
            } else {
                ContentUnavailableView(
                    "No Task Selected", systemImage: "checklist",
                    description: Text("Pick a task from the list."))
                    .accessibilityIdentifier("empty-detail")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddTaskView { title in
                store.add(title: title)
                showingAdd = false
            }
        }
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack {
            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.isDone ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(task.title)
                Text(task.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if task.priority == 2 {
                Text("High")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.15), in: Capsule())
            }
        }
    }
}

struct DetailView: View {
    @EnvironmentObject private var store: TaskStore
    let task: TaskItem

    private var current: TaskItem {
        store.tasks.first { $0.id == task.id } ?? task
    }

    var body: some View {
        Form {
            Section("Task") {
                LabeledContent("Title", value: current.title)
                LabeledContent("Status", value: current.isDone ? "Done" : "Open")
                    .accessibilityIdentifier("status")
            }
            Section {
                Button(current.isDone ? "Mark as Open" : "Mark as Done") {
                    store.toggle(current.id)
                }
                .accessibilityIdentifier("toggle-done")
            }
        }
        .navigationTitle(current.title)
    }
}

struct AddTaskView: View {
    @State private var title = ""
    let onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("new-title")
            }
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(title) }
                        .disabled(title.isEmpty)
                        .accessibilityIdentifier("save-task")
                }
            }
        }
    }
}
