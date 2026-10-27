import BeeKit
import BeeProtocol
import SwiftUI

/// First run: put the Bee in pairing mode and pick it.
struct OnboardingView: View {
    @Environment(BeeStore.self) private var store
    @State private var scanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                BeeArtwork(pairing: true)
                    .frame(width: 150, height: 150)
                    .padding(.top, 48)

                VStack(spacing: 8) {
                    Text("Pair Your Bee")
                        .font(.largeTitle.bold())
                    Text("Record with your Bee and read back what was said, with notes and to-dos. Everything stays on this iPhone.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 18) {
                    Step(number: 1, text: "Press the Bee's button 5 times quickly. Its light flashes blue and green while it's in pairing mode.")
                    Step(number: 2, text: store.pairingMethod == .accessorySetup
                        ? "Tap Set Up Bee and choose it in the sheet that appears."
                        : "Tap Find Bee and choose it from the list.")
                }
                .padding(20)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                Text("A Bee connects to one device at a time, so pairing here takes it over from the Mac or another phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if case let .unavailable(reason) = store.link {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    if store.pairingMethod == .accessorySetup { store.pair() } else { scanning = true }
                } label: {
                    HStack {
                        if store.isPairing { ProgressView().tint(.white) }
                        Text(store.pairingMethod == .accessorySetup ? "Set Up Bee" : "Find Bee")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .disabled(store.isPairing)

                Button("Try the Demo") { store.startDemo() }
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $scanning) { ScanView() }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.honey.gradient, in: .circle)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// CoreBluetooth fallback: Bees advertising nearby, strongest first.
struct ScanView: View {
    @Environment(BeeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.discoveries.sorted { $0.rssi > $1.rssi }) { discovery in
                        Button {
                            store.choose(discovery)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                BeeArtwork(light: .pairingBlue).frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(discovery.name ?? "Bee").font(.headline)
                                    Text(discovery.advertisement?.deviceID ?? discovery.id.uuidString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    if let advert = discovery.advertisement {
                                        Text(advert.hardware.title).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                SignalBars(rssi: discovery.rssi)
                            }
                        }
                        .tint(.primary)
                    }
                } footer: {
                    if store.discoveries.isEmpty {
                        Text("Looking for Bees in pairing mode. Press the button 5 times; the light flashes blue and green.")
                    }
                }
            }
            .overlay {
                if store.discoveries.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Nearby Bees")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .onAppear { store.startScan() }
        .onDisappear { store.stopScan() }
    }
}

#Preview {
    OnboardingView().environment(BeeStore(preview: true))
}
