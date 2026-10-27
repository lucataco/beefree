import BeePipeline
import SwiftData
import SwiftUI

/// Conversations by day, each with the day's digest, and search across everything said.
struct ConversationsView: View {
    @State private var search = ""

    var body: some View {
        NavigationStack {
            ConversationList(search: search)
                .navigationTitle("Conversations")
                .searchable(text: $search, prompt: "Search what was said")
                .navigationDestination(for: Conversation.self) { ConversationDetailView(conversation: $0) }
        }
    }
}

/// What's waiting to be processed, and a button to do it now.
struct ProcessingCard: View {
    @Environment(BeeStore.self) private var store
    @State private var backlog = Processor.Backlog()

    var body: some View {
        let processor = store.processor
        VStack(alignment: .leading, spacing: 10) {
            if let progress = processor.progress {
                HStack {
                    Text(progress.step).font(.headline)
                    Spacer()
                    Text("\(min(progress.done + 1, progress.total)) of \(progress.total)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: progress.fraction)
                Button("Stop", role: .cancel) { processor.cancel() }
                    .font(.subheadline)
            } else if let downloading = processor.downloading {
                Text("Downloading Parakeet").font(.headline)
                ProgressView(value: downloading)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(backlog.isEmpty ? "All caught up" : waiting).font(.headline)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !backlog.isEmpty {
                    Button("Process Now") { store.processNow() }
                        .buttonStyle(.glassProminent)
                        .tint(.honey)
                }
            }
            if let error = processor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let reason = NoteTaker.availability.explanation {
                Label(reason, systemImage: "apple.intelligence")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: processor.isRunning) { backlog = processor.backlog }
        .task {
            // The backlog grows as segments close.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                backlog = processor.backlog
            }
        }
    }

    private var waiting: String {
        var parts: [String] = []
        if backlog.segments > 0 { parts.append("\(backlog.segments) recording\(backlog.segments == 1 ? "" : "s")") }
        if backlog.conversations > 0 { parts.append("\(backlog.conversations) conversation\(backlog.conversations == 1 ? "" : "s")") }
        if backlog.notes > 0 && backlog.conversations == 0 { parts.append("\(backlog.notes) to summarize") }
        return parts.joined(separator: ", ") + " to process"
    }

    private var subtitle: String {
        if backlog.isEmpty, let finished = store.processor.lastFinished {
            let when = "Processed \(finished.formatted(.relative(presentation: .named)))"
            return store.processor.lastOutcome.map { "\(when): \($0)." } ?? "\(when)."
        }
        return "Or wait: FreeBee processes overnight while your iPhone charges."
    }
}

private struct ConversationList: View {
    @Environment(BeeStore.self) private var store
    @Query(sort: \Conversation.start, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \DayNote.day, order: .reverse) private var days: [DayNote]
    var search: String

    var body: some View {
        List {
            Section { ProcessingCard() }
            let shown = filtered
            if shown.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No Conversations Yet" : "No Matches", systemImage: search.isEmpty ? "text.bubble" : "magnifyingglass")
                } description: {
                    Text(search.isEmpty
                        ? "Press your Bee's button to record. What you say shows up here once it's processed."
                        : "Nothing said matches \u{201C}\(search)\u{201D}.")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(grouped(shown), id: \.day) { group in
                Section {
                    if search.isEmpty, let note = days.first(where: { $0.day == group.day }) {
                        DigestCard(note: note)
                    }
                    ForEach(group.items) { conversation in
                        NavigationLink(value: conversation) { ConversationRow(conversation: conversation) }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.processor.delete(group.items[index], withAudio: true) }
                    }
                } header: {
                    Text(dayTitle(group.day))
                }
            }
        }
    }

    private var filtered: [Conversation] {
        let needle = search.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return conversations }
        return conversations.filter { c in
            [c.title, c.summary].compactMap { $0 }.contains { $0.localizedStandardContains(needle) }
                || c.topics.contains { $0.localizedStandardContains(needle) }
                || c.lines.contains { $0.text.localizedStandardContains(needle) }
        }
    }

    private func grouped(_ items: [Conversation]) -> [(day: Date, items: [Conversation])] {
        let calendar = Calendar.current
        return Dictionary(grouping: items) { calendar.startOfDay(for: $0.start) }
            .map { ($0.key, $0.value.sorted { $0.start > $1.start }) }
            .sorted { $0.day > $1.day }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct DigestCard: View {
    var note: DayNote

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(note.headline, systemImage: "sun.horizon.fill")
                .font(.system(.headline, design: .serif))
            if !note.commitments.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(note.commitments, id: \.self) { commitment in
                        Label(commitment, systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                }
            }
            if !note.highlights.isEmpty {
                Text(note.highlights.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ConversationRow: View {
    var conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(conversation.displayTitle)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(conversation.stage == .pending ? .secondary : .primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(conversation.start, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let summary = conversation.summary {
                Text(summary)
                    .font(.system(.subheadline, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                Label(Format.duration(conversation.speechSeconds), systemImage: "waveform")
                    .accessibilityLabel("\(Format.duration(conversation.speechSeconds)) of speech")
                if !conversation.speakers.isEmpty {
                    Label("\(conversation.speakers.count)", systemImage: conversation.speakers.count == 1 ? "person" : "person.2")
                }
                if !conversation.todos.isEmpty {
                    Label("\(conversation.todos.count)", systemImage: "checklist")
                }
                if conversation.soundsLikeMedia {
                    Label("Media", systemImage: "tv")
                }
                if conversation.stage == .failed {
                    Label("Failed", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 2)
        .opacity(conversation.soundsLikeMedia ? 0.6 : 1)
    }

}

struct TodoRow: View {
    @Environment(\.modelContext) private var context
    var todo: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                todo.state = todo.state == .done ? .inbox : .done
                try? context.save()
            } label: {
                Image(systemName: todo.state == .done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.state == .done ? Color.honey : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.state == .done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.task)
                    .strikethrough(todo.state == .done)
                if !todo.due.isEmpty {
                    Label(todo.due, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !todo.quote.isEmpty {
                    Text("\u{201C}\(todo.quote)\u{201D}")
                        .font(.system(.footnote, design: .serif))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let conversation = todo.conversation {
                    NavigationLink(value: conversation) {
                        Text(conversation.displayTitle)
                            .font(.caption.weight(.medium))
                    }
                }
            }
        }
        .swipeActions {
            Button("Dismiss", systemImage: "xmark", role: .destructive) {
                todo.state = .dismissed
                try? context.save()
            }
        }
    }
}
