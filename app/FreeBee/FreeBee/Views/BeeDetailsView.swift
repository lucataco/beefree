import BeeKit
import BeeProtocol
import SwiftData
import SwiftUI

/// Everything about the Bee itself: battery, light, sleep and power, the audio link, and its details.
struct BeeDetailsView: View {
    @Environment(BeeStore.self) private var store
    @State private var brightness: Double = 50
    @State private var editingBrightness = false
    @State private var confirmPowerOff = false

    var body: some View {
        let ready = store.link == .ready
        List {
            Section {
                LabeledContent("Battery") {
                    HStack(spacing: 6) {
                        BatteryLabel(percent: store.status.battery, charging: store.status.charging ?? false)
                        if store.status.charging == true { Text("charging").foregroundStyle(.secondary) }
                    }
                }
                LabeledContent("State", value: store.status.state?.title ?? "–")
                LabeledContent("Connection") {
                    HStack(spacing: 8) {
                        Text(store.link.label)
                        if ready { SignalBars(rssi: store.rssi) }
                    }
                }
            }

            Section("Light") {
                Slider(value: $brightness, in: 0...100, step: 1) {
                    Text("Brightness")
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                } onEditingChanged: { editing in
                    editingBrightness = editing
                    if !editing { Task { await store.setBrightness(Int(brightness)) } }
                }
                .accessibilityValue("\(Int(brightness)) percent")
            }
            .disabled(!ready)

            Section {
                Menu {
                    Button("Hardware voice detection", systemImage: "cpu") { Task { await store.sleep(.sleepHardwareVAD) } }
                    Button("Software voice detection", systemImage: "waveform.badge.magnifyingglass") { Task { await store.sleep(.sleepSoftwareVAD) } }
                } label: {
                    HStack {
                        Label("Sleep", systemImage: "moon.zzz")
                        Spacer()
                        if store.busy.contains(.sleep) { ProgressView() }
                    }
                }
                Button(role: .destructive) {
                    confirmPowerOff = true
                } label: {
                    Label("Turn Off", systemImage: "power")
                }
            }
            .disabled(!ready)

            AudioLinkSection()

            Section("About This Bee") {
                NavigationLink {
                    FirmwareView()
                } label: {
                    LabeledContent("Firmware") {
                        HStack(spacing: 6) {
                            Text(store.status.firmware?.description ?? "–")
                            if let firmware = store.status.firmware, firmware < .newestPublic {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("A newer version exists")
                            }
                        }
                    }
                }
                NavigationLink {
                    KeyView()
                } label: {
                    LabeledContent("Audio key", value: store.hasKeyForThisBee ? "On file" : "Not imported")
                }
                ValueRow(title: "Device ID", value: store.status.deviceID ?? "–", monospaced: true)
                ValueRow(title: "Hardware", value: store.status.hardware?.title ?? "–")
                ValueRow(title: "Codec", value: store.status.codec?.title ?? "–")
            }

            if let simulator = store.simulator, ready {
                Section {
                    Button("Double-press the button", systemImage: "hand.tap") { simulator.pressDouble() }
                    Button("Hold the button", systemImage: "hand.point.up") { simulator.hold() }
                    Button(
                        simulator.charging ? "Take off the charger" : "Put on the charger",
                        systemImage: "bolt"
                    ) { simulator.setCharging(!simulator.charging) }
                } header: {
                    Text("Demo")
                } footer: {
                    Text("This is a simulated Bee. Pair a real one from Settings.")
                }
            }
        }
        .navigationTitle(store.known?.name ?? "Your Bee")
        .refreshable { await store.refreshNow() }
        .onAppear { syncBrightness() }
        .onChange(of: store.status.brightness) { syncBrightness() }
        .confirmationDialog("Turn off the Bee?", isPresented: $confirmPowerOff, titleVisibility: .visible) {
            Button("Turn Off Bee", role: .destructive) { Task { await store.powerOff() } }
        } message: {
            Text("It disconnects right away. Turn it back on at the Bee; this iPhone reconnects when it's back.")
        }
    }

    private func syncBrightness() {
        guard !editingBrightness, let value = store.status.brightness else { return }
        brightness = Double(value)
    }
}

/// What the link is carrying: today's audio and this connection's packets.
private struct AudioLinkSection: View {
    @Environment(BeeStore.self) private var store
    @Query private var today: [AudioSegment]

    init() {
        let midnight = Calendar.current.startOfDay(for: .now)
        _today = Query(filter: #Predicate<AudioSegment> { $0.start >= midnight }, sort: \.start)
    }

    var body: some View {
        Section {
            LabeledContent("Today", value: Format.duration(today.reduce(0) { $0 + $1.duration }))
            LabeledContent("Speech today", value: Format.duration(today.reduce(0) { $0 + $1.speechSeconds }))
            LabeledContent("Stored today", value: ByteCountFormatter.string(fromByteCount: Int64(today.reduce(0) { $0 + $1.bytes }), countStyle: .file))
            let stats = store.capture.stats
            if stats.packets > 0 {
                LabeledContent("Packets this connection", value: "\(stats.packets)")
                LabeledContent("Packets lost", value: stats.lostPackets == 0 ? "None" : String(format: "%.1f%%", stats.lossRate * 100))
                LabeledContent("Link", value: "MTU \(store.capture.maximumNotificationLength + 3)")
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("Audio goes straight to this iPhone, encrypted, and is stored here as it arrives. The Bee keeps none, so anything said while it isn't connected is lost.")
        }
    }
}

#Preview {
    NavigationStack { BeeDetailsView() }.environment(BeeStore(preview: true))
}
