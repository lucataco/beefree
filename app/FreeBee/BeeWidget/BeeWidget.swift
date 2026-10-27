import SwiftUI
import WidgetKit

/// Battery and current state on the Home Screen and Lock Screen. The app pushes a new snapshot
/// (and reloads this timeline) whenever the battery, charging, state or connection changes.
@main
struct BeeWidgetBundle: WidgetBundle {
    var body: some Widget {
        BeeStatusWidget()
        CaptureLiveActivity()
    }
}

struct BeeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BeeSnapshot.widgetKind, provider: Provider()) { entry in
            BeeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Bee Status")
        .description("Battery and what your Bee is doing.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: BeeSnapshot?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, snapshot: context.isPreview ? .placeholder : BeeSnapshot.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, snapshot: BeeSnapshot.load())], policy: .never))
    }
}

struct BeeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: Entry

    private static let honey = Color(red: 0.886, green: 0.580, blue: 0.043)

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: inline(snapshot)
            default: small(snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "circle.circle")
                    .font(.title)
                Text("Open FreeBee to pair")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func small(_ snapshot: BeeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.name).font(.headline).lineLimit(1)
                Spacer()
                Circle()
                    .fill(snapshot.connected ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(snapshot.connected ? "Connected" : "Not connected")
            }
            Gauge(value: Double(snapshot.battery ?? 0), in: 0...100) {
                Image(systemName: "battery.100")
            } currentValueLabel: {
                HStack(spacing: 1) {
                    Text(snapshot.battery.map { "\($0)" } ?? "–")
                    if snapshot.charging { Image(systemName: "bolt.fill") }
                }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(snapshot.charging ? .green : (snapshot.battery ?? 100) <= 20 ? .red : BeeWidgetView.honey)
            .scaleEffect(1.15)
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            Label(snapshot.connected ? snapshot.activity.label : "Not connected", systemImage: snapshot.connected ? snapshot.activity.symbol : "antenna.radiowaves.left.and.right.slash")
                .font(.caption.weight(.semibold))
            Text(snapshot.updated, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fontDesign(.rounded)
    }

    private func circular(_ snapshot: BeeSnapshot) -> some View {
        Gauge(value: Double(snapshot.battery ?? 0), in: 0...100) {
            Image(systemName: snapshot.activity.symbol)
        } currentValueLabel: {
            Text(snapshot.battery.map { "\($0)" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private func rectangular(_ snapshot: BeeSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(snapshot.name, systemImage: "circle.circle.fill").font(.headline).widgetAccentable()
            Text(snapshot.connected ? snapshot.activity.label : "Not connected")
            Text(snapshot.battery.map { "\($0)%" + (snapshot.charging ? " · charging" : "") } ?? "Battery unknown")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ snapshot: BeeSnapshot) -> some View {
        Label(
            "\(snapshot.battery.map { "\($0)%" } ?? "–") · \(snapshot.connected ? snapshot.activity.label : "Not connected")",
            systemImage: snapshot.charging ? "bolt.fill" : snapshot.activity.symbol
        )
    }
}

#Preview(as: .systemSmall) {
    BeeStatusWidget()
} timeline: {
    Entry(date: .now, snapshot: .placeholder)
    Entry(date: .now, snapshot: BeeSnapshot(name: "Bee", battery: 14, charging: false, activity: .muted, connected: false, updated: .now))
}
