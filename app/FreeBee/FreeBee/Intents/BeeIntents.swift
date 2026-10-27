import AppIntents

/// Shortcuts and Siri: "Mute my Bee with FreeBee", "Unmute my Bee with FreeBee", "FreeBee battery".
struct MuteBeeIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute Bee"
    static let description = IntentDescription("Turns your Bee's microphone off. Needs the audio key.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BeeStore.shared.setMutedFromIntent(true)
        return .result(dialog: "Your Bee is muted.")
    }
}

struct UnmuteBeeIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute Bee"
    static let description = IntentDescription("Turns your Bee's microphone back on. Needs the audio key.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BeeStore.shared.setMutedFromIntent(false)
        return .result(dialog: "Your Bee is listening.")
    }
}

struct BeeBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Bee Battery"
    static let description = IntentDescription("Reports your Bee's battery level.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let store = BeeStore.shared
        guard await store.waitUntilReady(), let percent = store.status.battery else {
            throw StoreError("Your Bee isn't connected.")
        }
        let charging = store.status.charging == true ? " and charging" : ""
        return .result(value: percent, dialog: "Your Bee is at \(percent)%\(charging).")
    }
}

struct BeeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: MuteBeeIntent(),
            phrases: ["Mute my Bee with \(.applicationName)", "Mute my Bee in \(.applicationName)"],
            shortTitle: "Mute Bee",
            systemImageName: "mic.slash"
        )
        AppShortcut(
            intent: UnmuteBeeIntent(),
            phrases: ["Unmute my Bee with \(.applicationName)", "Unmute my Bee in \(.applicationName)"],
            shortTitle: "Unmute Bee",
            systemImageName: "mic"
        )
        AppShortcut(
            intent: BeeBatteryIntent(),
            phrases: ["\(.applicationName) battery", "Check my Bee's battery in \(.applicationName)"],
            shortTitle: "Bee Battery",
            systemImageName: "battery.75percent"
        )
    }
}
