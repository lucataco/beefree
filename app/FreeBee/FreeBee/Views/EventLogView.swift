import BeeProtocol
import SwiftData
import SwiftUI

/// Timestamped button presses, battery, charging, state, connection and app events. Pushed from Settings.
struct EventLogView: View {
    @Environment(BeeStore.self) private var store
    @State private var filter: LogEntry.Kind?
    @State private var confirmClear = false

    var body: some View {
        EventList(filter: filter)
            .navigationTitle("Event Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Show", selection: $filter) {
                            Text("All Events").tag(LogEntry.Kind?.none)
                            ForEach(LogEntry.Kind.allCases) { kind in
                                Label(kind.title, systemImage: kind.symbol).tag(Optional(kind))
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: filter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    }
                    Menu {
                        ExportButton()
                        Button("Clear Log…", systemImage: "trash", role: .destructive) { confirmClear = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .confirmationDialog("Clear the event log?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear Log", role: .destructive) { store.clearLog() }
            } message: {
                Text("Every event on this iPhone is deleted. The Bee doesn't keep a copy.")
            }
    }
}

private struct EventList: View {
    @Query private var entries: [LogEntry]
    private let filter: LogEntry.Kind?

    init(filter: LogEntry.Kind?) {
        self.filter = filter
        var descriptor = FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        if let raw = filter?.rawValue {
            descriptor.predicate = #Predicate { $0.kindRaw == raw }
        }
        descriptor.fetchLimit = 2000
        _entries = Query(descriptor, animation: .default)
    }

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label(filter == nil ? "No Events Yet" : "No \(filter!.title) Events", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Double-press or hold the Bee's button, or wait for a battery change. Events are logged while the app is in the background too.")
            }
        } else {
            List {
                ForEach(days, id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.entries) { EventRow(entry: $0) }
                    }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var days: [(day: Date, entries: [LogEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }
}

private struct EventRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(entry.kind.color.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                if entry.code != 0 {
                    Text(String(format: "0x%04X", entry.code) + (entry.payload.isEmpty ? "" : " · \(entry.payload.hex)"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            // Take the width the time doesn't need, so short texts don't wrap early.
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shares the whole log as CSV.
private struct ExportButton: View {
    @Query(sort: \LogEntry.timestamp) private var entries: [LogEntry]

    var body: some View {
        ShareLink(item: EventCSV(entries: entries), preview: SharePreview("Bee events", image: Image(systemName: "list.bullet.rectangle"))) {
            Label("Export as CSV", systemImage: "square.and.arrow.up")
        }
        .disabled(entries.isEmpty)
    }
}

#Preview {
    let store = BeeStore(preview: true)
    NavigationStack { EventLogView() }.environment(store).modelContainer(store.container)
}
