import BeeKit
import BeeProtocol
import SwiftUI

/// Installed firmware, the backup slot and the bootloader, from read-only SMP queries (as in `beekit fw`).
struct FirmwareView: View {
    @Environment(BeeStore.self) private var store

    var body: some View {
        List {
            Section {
                LabeledContent("Running", value: store.status.firmware?.description ?? "–")
                if let running = store.status.firmware {
                    if running < FirmwareVersion.newestPublic {
                        Label {
                            Text("A newer version exists: \(FirmwareVersion.newestPublic.description) has been reported publicly. Updates can change the protocol, so staying on \(running.description) is recommended.")
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Color.honey)
                        }
                        .font(.subheadline)
                    } else {
                        Label("Newest version reported publicly", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("Installed")
            }

            if let report = store.firmware {
                Section("Image slots") {
                    lookup(report.slots) { slots in
                        ForEach(slots) { SlotRow(slot: $0) }
                    }
                }
                Section("Bootloader") {
                    lookup(report.bootloader) { Text($0) }
                }
                Section("SMP buffers") {
                    lookup(report.parameters) { params in
                        LabeledContent("Size", value: params.bufferSize.map(String.init) ?? "–")
                        LabeledContent("Count", value: params.bufferCount.map(String.init) ?? "–")
                    }
                }
                Section("OS / app info") {
                    lookup(report.appInfo) { Text($0.isEmpty ? "Empty" : $0).font(.footnote.monospaced()) }
                }
            } else if store.busy.contains(.firmware) {
                Section {
                    HStack {
                        ProgressView()
                        Text("Asking the Bee…").foregroundStyle(.secondary)
                    }
                }
            } else if store.link != .ready {
                Section {
                    Text("Connect to the Bee to read its image slots and bootloader.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
            } footer: {
                Text("Read-only. This screen only sends SMP read requests (op 0); the app has no way to upload, erase, test or confirm a firmware image.")
            }
        }
        .navigationTitle("Firmware")
        .toolbar {
            Button("Reload", systemImage: "arrow.clockwise") { Task { await store.loadFirmware() } }
                .disabled(store.link != .ready || store.busy.contains(.firmware))
        }
        .task {
            if store.firmware == nil, store.link == .ready { await store.loadFirmware() }
        }
    }

    @ViewBuilder
    private func lookup<Value, Content: View>(_ lookup: Lookup<Value>, @ViewBuilder content: (Value) -> Content) -> some View {
        switch lookup {
        case let .value(value): content(value)
        case .unsupported: Text("Not supported by this Bee (ENOTSUP)").foregroundStyle(.secondary)
        case let .failed(reason): Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

private struct SlotRow: View {
    let slot: ImageSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Slot \(slot.slot)").font(.headline)
                Spacer()
                Text(slot.version).font(.headline.monospacedDigit())
            }
            HStack(spacing: 6) {
                Text(slot.active ? "Running" : "Backup")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(slot.active ? Color.honey : .secondary)
                ForEach(slot.flags, id: \.self) { flag in
                    Text(flag)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }
            if let hash = slot.hash {
                Text("sha256 \(hash.hex.prefix(16))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack { FirmwareView() }.environment(BeeStore(preview: true))
}
