import BeePipeline
import BeeProtocol
import SwiftUI

struct SettingsView: View {
    @Environment(BeeStore.self) private var store
    @AppStorage(Alerts.lowBatteryKey) private var lowBattery = false
    @AppStorage(Alerts.thresholdKey) private var threshold = Alerts.defaultThreshold
    @AppStorage(Alerts.disconnectKey) private var disconnect = false
    @AppStorage(Alerts.digestKey) private var digest = false
    @State private var confirmForget = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            Form {
                if let known = store.known {
                    Section {
                        LabeledContent("Name", value: known.name)
                        if !known.isDemo {
                            LabeledContent("Paired", value: known.pairedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        Button(known.isDemo ? "Leave Demo" : "Forget This Bee", role: .destructive) { confirmForget = true }
                    } header: {
                        Text("Bee")
                    } footer: {
                        if !known.isDemo {
                            Text("To pair again, press the Bee's button 5 times (the light flashes blue and green). After pairing it with another device, like the Mac, pair it with this iPhone again.")
                        }
                    }
                }

                Section("Recording") {
                    NavigationLink {
                        KeyView()
                    } label: {
                        LabeledContent("Audio Key", value: store.hasKeyForThisBee ? "On file" : "Not imported")
                    }
                    NavigationLink {
                        ProcessingSettingsView()
                    } label: {
                        LabeledContent("Transcription", value: store.processor.engine.title)
                    }
                }

                Section {
                    Toggle("Low battery", isOn: $lowBattery)
                    if lowBattery {
                        Stepper("Alert at \(threshold)%", value: $threshold, in: 5...50, step: 5)
                    }
                    Toggle("Bee disconnected", isOn: $disconnect)
                    Toggle("Day's digest", isOn: $digest)
                } header: {
                    Text("Alerts")
                } footer: {
                    if notificationsDenied {
                        Text("Notifications are off for FreeBee. Turn them on in Settings › Notifications.")
                    } else {
                        Text("A disconnect alert waits a minute, so walking out of range briefly stays quiet.")
                    }
                }
                .onChange(of: lowBattery) { if $1 { requestNotifications() } }
                .onChange(of: disconnect) { if $1 { requestNotifications() } }
                .onChange(of: digest) { if $1 { requestNotifications() } }

                Section {
                    NavigationLink("Event Log") { EventLogView() }
                    NavigationLink("Radio Settings") { AdvancedView() }
                } header: {
                    Text("Troubleshooting")
                } footer: {
                    Text("The event log records the Bee's button, battery and connection, kept 60 days. Radio settings are untested writes.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                } footer: {
                    Text("FreeBee talks only to your Bee. There's no account or server: audio, transcripts, notes, the event log and the key stay on this iPhone. The one download is the Parakeet speech model.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                store.isDemo ? "Leave the demo?" : "Forget this Bee?",
                isPresented: $confirmForget,
                titleVisibility: .visible
            ) {
                Button(store.isDemo ? "Leave Demo" : "Forget Bee", role: .destructive) { Task { await store.forget() } }
            } message: {
                if !store.isDemo {
                    Text("This iPhone disconnects and stops reconnecting. The audio key and event log are kept.")
                }
            }
        }
    }

    private func requestNotifications() {
        Task { notificationsDenied = !(await store.alerts.requestAuthorization()) }
    }
}

/// TX power (C001) and bitrate (C008). Reads are safe; writes are untested on our unit.
struct AdvancedView: View {
    @Environment(BeeStore.self) private var store
    @State private var understood = false
    @State private var txPower = 0
    @State private var bitrate = 32000

    private static let bitrates = [16000, 24000, 32000, 48000, 64000]

    var body: some View {
        Form {
            Section {
                LabeledContent("TX level", value: store.status.txLevel.map(String.init) ?? "–")
                LabeledContent("Bitrate", value: store.status.bitrate.map { "\($0 / 1000) kbps" } ?? "–")
                LabeledContent("Sealed", value: store.status.sealed.map { $0 ? "Yes" : "No" } ?? "–")
                if let mv = store.status.millivolts { LabeledContent("Battery voltage", value: "\(mv) mV") }
            } header: {
                Text("Current")
            }

            Section {
                Toggle("I understand these writes are untested", isOn: $understood)
            } footer: {
                Text("They're in the protocol, but nobody has confirmed what they do to a Bee. A wrong bitrate could affect audio recorded by the Bee.")
            }

            Section("TX power") {
                Stepper("\(txPower) dBm", value: $txPower, in: -40...8, step: 4)
                Button("Set TX Power") { Task { await store.setTxPower(txPower) } }
            }
            .disabled(!understood || store.link != .ready)

            Section("Bitrate") {
                Picker("Bitrate", selection: $bitrate) {
                    ForEach(Self.bitrates, id: \.self) { Text("\($0 / 1000) kbps").tag($0) }
                }
                Button("Set Bitrate") { Task { await store.setBitrate(bitrate) } }
            }
            .disabled(!understood || store.link != .ready)
        }
        .navigationTitle("Radio Settings")
        .toolbar {
            if store.busy.contains(.radio) { ProgressView() }
        }
        .task {
            await store.loadRadio()
            if let current = store.status.bitrate, Self.bitrates.contains(current) { bitrate = current }
        }
    }
}

#Preview {
    SettingsView().environment(BeeStore(preview: true))
}
