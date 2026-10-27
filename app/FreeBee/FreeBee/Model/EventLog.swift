import BeeProtocol
import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

@Model
final class LogEntry {
    enum Kind: String, CaseIterable, Identifiable {
        case button, state, battery, charging, connection, audio, app, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .button: "Button"
            case .state: "State"
            case .battery: "Battery"
            case .charging: "Charging"
            case .connection: "Connection"
            case .audio: "Audio"
            case .app: "App"
            case .other: "Other"
            }
        }
    }

    var timestamp: Date
    var kindRaw: String
    var text: String
    /// Event code (A001-A005), or 0 for entries the app wrote itself.
    var code: Int
    var payload: Data
    var deviceID: String?

    init(timestamp: Date = .now, kind: Kind, text: String, code: Int = 0, payload: Data = Data(), deviceID: String? = nil) {
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.text = text
        self.code = code
        self.payload = payload
        self.deviceID = deviceID
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .other }
}

/// Writes the event history. It stays on this iPhone.
final class EventLog {
    static let retention: TimeInterval = 60 * 24 * 60 * 60

    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        prune()
    }

    /// `source` says who changed the state: "in the app", "from the Bee".
    func record(_ event: BeeEvent, deviceID: String?, source: String? = nil) {
        let (kind, text, code, payload): (LogEntry.Kind, String, EventCode?, Data) = switch event {
        case .doublePress: (.button, "Double press", .buttonDoublePress, Data())
        case let .hold(pressed): (.button, pressed ? "Button held" : "Button released", .buttonHold, Data([pressed ? 1 : 0]))
        case let .state(status):
            (.state, "\(status.state.title) · \(status.state.detail)" + (source.map { " · \($0)" } ?? ""), .deviceState, Data([status.state.rawValue] + (status.codec.map { [$0.rawValue] } ?? [])))
        case let .battery(level):
            (.battery, "Battery \(level.percent)%" + (level.millivolts.map { " (\($0) mV)" } ?? ""), .battery, Data([UInt8(clamping: level.percent)]))
        case let .charging(on): (.charging, on ? "Charging started" : "Charging stopped", .charging, Data([on ? 1 : 0]))
        case let .other(code, payload): (.other, BeeEvent.other(code: code, payload: payload).description, EventCode(rawValue: code), payload)
        }
        insert(LogEntry(kind: kind, text: text, code: Int(code?.rawValue ?? 0), payload: payload, deviceID: deviceID))
    }

    func note(_ kind: LogEntry.Kind, _ text: String, deviceID: String? = nil, at timestamp: Date = .now) {
        insert(LogEntry(timestamp: timestamp, kind: kind, text: text, deviceID: deviceID))
    }

    /// When the newest entry was written.
    var latest: Date? {
        var descriptor = FetchDescriptor<LogEntry>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.timestamp
    }

    func clear() {
        try? context.delete(model: LogEntry.self)
        try? context.save()
    }

    private func insert(_ entry: LogEntry) {
        context.insert(entry)
        // Save right away: in the background the app may be suspended again within seconds.
        try? context.save()
    }

    private func prune() {
        let cutoff = Date.now.addingTimeInterval(-EventLog.retention)
        try? context.delete(model: LogEntry.self, where: #Predicate { $0.timestamp < cutoff })
        try? context.save()
    }
}

/// The event log as CSV, built only when someone actually shares it.
struct EventCSV: Transferable {
    struct Row: Sendable {
        var timestamp: Date
        var kind: String
        var text: String
        var code: Int
        var payload: String
        var deviceID: String
    }

    var rows: [Row]

    init(entries: [LogEntry]) {
        rows = entries.map {
            Row(timestamp: $0.timestamp, kind: $0.kindRaw, text: $0.text, code: $0.code, payload: $0.payload.hex, deviceID: $0.deviceID ?? "")
        }
    }

    nonisolated static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { csv in
            Data(csv.text.utf8)
        }
        .suggestedFileName("bee-events.csv")
    }

    nonisolated var text: String {
        let formatter = ISO8601DateFormatter()
        let quote = { (s: String) in "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = rows.map { row in
            [formatter.string(from: row.timestamp), row.kind, quote(row.text), row.code == 0 ? "" : String(format: "%04X", row.code), row.payload, row.deviceID]
                .joined(separator: ",")
        }
        return (["timestamp,kind,text,code,payload,device_id"] + lines).joined(separator: "\n") + "\n"
    }
}
