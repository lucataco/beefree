import Foundation
import UserNotifications

/// Local notifications: low battery, "your Bee has been gone a while" and the day's digest. All are off
/// until turned on in Settings.
final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    static let lowBatteryKey = "alerts.lowBattery"
    static let thresholdKey = "alerts.lowBatteryThreshold"
    static let disconnectKey = "alerts.disconnect"
    static let digestKey = "alerts.digest"
    static let defaultThreshold = 20
    /// A disconnect only alerts if the Bee stays away this long, so walking out of range briefly is quiet.
    static let disconnectGrace: TimeInterval = 60

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var lowBatteryNotified = false
    private let disconnectID = "bee.disconnected"

    override init() {
        super.init()
        center.delegate = self
        defaults.register(defaults: [Alerts.thresholdKey: Alerts.defaultThreshold])
    }

    var threshold: Int { defaults.integer(forKey: Alerts.thresholdKey) }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func battery(percent: Int?, charging: Bool?, name: String) {
        guard let percent else { return }
        if charging == true || percent > threshold + 5 {
            lowBatteryNotified = false
            return
        }
        guard defaults.bool(forKey: Alerts.lowBatteryKey), percent <= threshold, !lowBatteryNotified else { return }
        lowBatteryNotified = true
        post(id: "bee.lowBattery", title: "\(name) battery low", body: "\(percent)% left. Put it on the charger soon.")
    }

    func disconnected(name: String) {
        guard defaults.bool(forKey: Alerts.disconnectKey) else { return }
        post(
            id: disconnectID,
            title: "\(name) disconnected",
            body: "It's been out of reach for a minute. It reconnects by itself when it's back in range.",
            after: Alerts.disconnectGrace
        )
    }

    /// Commitments first: they're what people found useful in an end-of-day recap.
    func digest(day: Date, headline: String, commitments: [String]) {
        guard defaults.bool(forKey: Alerts.digestKey) else { return }
        var body = headline
        if !commitments.isEmpty {
            body += "\n" + commitments.prefix(3).map { "• \($0)" }.joined(separator: "\n")
            if commitments.count > 3 { body += "\n+\(commitments.count - 3) more" }
        }
        post(id: "bee.digest.\(Int(day.timeIntervalSince1970))", title: commitments.isEmpty ? "Your day" : "Your day: \(commitments.count) to follow up", body: body)
    }

    func reconnected() {
        center.removePendingNotificationRequests(withIdentifiers: [disconnectID])
    }

    private func post(id: String, title: String, body: String, after delay: TimeInterval? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    // Show alerts while the app is open too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
