import BeePipeline
import SwiftData
import SwiftUI

/// The to-do tab: things you said you'd do, newest day first, each with the words it came from.
struct TodosView: View {
    var body: some View {
        NavigationStack {
            TodoList()
                .navigationTitle("To-dos")
                .navigationDestination(for: Conversation.self) { ConversationDetailView(conversation: $0) }
        }
    }
}

/// The inbox: to-dos for the wearer, capped per day so it stays reviewable, each linked to its quote.
private struct TodoList: View {
    @Query(sort: \TodoItem.created, order: .reverse) private var todos: [TodoItem]
    @State private var showDone = false
    private static let dailyCap = 5

    var body: some View {
        List {
            let open = todos.filter { $0.state == .inbox && $0.owner != .someoneElse }
            if open.isEmpty {
                ContentUnavailableView(
                    "Nothing to Do",
                    systemImage: "checklist",
                    description: Text("Things you agree to do in conversations show up here, with the words they came from.")
                )
                .listRowBackground(Color.clear)
            }
            ForEach(byDay(open), id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
                    ForEach(group.items.prefix(TodoList.dailyCap)) { TodoRow(todo: $0) }
                    if group.items.count > TodoList.dailyCap {
                        DisclosureGroup("\(group.items.count - TodoList.dailyCap) more") {
                            ForEach(group.items.dropFirst(TodoList.dailyCap)) { TodoRow(todo: $0) }
                        }
                    }
                }
            }
            let done = todos.filter { $0.state == .done }
            if !done.isEmpty {
                Section {
                    DisclosureGroup("Done (\(done.count))", isExpanded: $showDone) {
                        ForEach(done) { TodoRow(todo: $0) }
                    }
                }
            }
        }
    }

    private func byDay(_ items: [TodoItem]) -> [(day: Date, items: [TodoItem])] {
        let calendar = Calendar.current
        return Dictionary(grouping: items) { calendar.startOfDay(for: $0.created) }
            .map { ($0.key, $0.value) }
            .sorted { $0.day > $1.day }
    }
}
