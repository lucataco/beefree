import BeeProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Imports the pairing token captured on the Mac (`beekit import-key`) into the Keychain.
struct KeyView: View {
    @Environment(BeeStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var pasting = false
    @State private var pasted = ""
    @State private var result: StoreAlert?
    /// Shown as a sheet when mute was tapped without a key.
    var isSheet = false

    var body: some View {
        List {
            Section {
                Label {
                    Text("Mute and unmute only stick inside a session opened with this Bee's pairing token. Everything else works without it.")
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(Color.honey)
                }
            }

            if let deviceID = store.status.deviceID ?? store.known?.deviceID {
                Section("This Bee") {
                    ValueRow(title: "Device ID", value: deviceID, monospaced: true)
                    if let fingerprint = store.storedKeys[deviceID] {
                        ValueRow(title: "Key", value: "#\(fingerprint)", monospaced: true)
                        if !store.isDemo {
                            Button("Delete Key", role: .destructive) { store.deleteKey(deviceID: deviceID) }
                        }
                    } else {
                        LabeledContent("Key", value: "Not imported")
                    }
                }
            }

            Section {
                Button("Import secrets.json…", systemImage: "doc.badge.plus") { importing = true }
                Button("Paste Token…", systemImage: "doc.on.clipboard") { pasting = true }
            } header: {
                Text("Import")
            } footer: {
                Text("On the Mac, AirDrop ~/.config/beekit/secrets.json to this iPhone and open it with FreeBee, or save it to Files and import it here. The key fingerprint matches the key# that beekit prints.")
            }

            let others = store.storedKeys.filter { $0.key != store.status.deviceID }.sorted { $0.key < $1.key }
            if !others.isEmpty {
                Section("Other Bees") {
                    ForEach(others, id: \.key) { id, fingerprint in
                        ValueRow(title: id, value: "#\(fingerprint)", monospaced: true)
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.deleteKey(deviceID: id) }
                            }
                    }
                }
            }
        }
        .navigationTitle("Audio Key")
        .toolbar {
            if isSheet {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { outcome in
            do {
                let entries = try store.importKeys(from: outcome.get())
                result = StoreAlert("Key imported", "Saved \(entries.count == 1 ? "the key" : "\(entries.count) keys") for \(entries.map(\.deviceID).joined(separator: ", ")).")
            } catch {
                result = StoreAlert("Couldn't import the key", error: error)
            }
        }
        .sheet(isPresented: $pasting) {
            PasteTokenView(text: $pasted) {
                do {
                    let token = try store.importKey(hex: pasted)
                    pasted = ""
                    result = StoreAlert("Key imported", "Saved the key for \(token.deviceID) (#\(token.fingerprint)).")
                } catch {
                    result = StoreAlert("That isn't a pairing token", error: error)
                }
            }
        }
        .alert(item: $result) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

private struct PasteTokenView: View {
    @Binding var text: String
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 160)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The token_hex value from secrets.json: 108 bytes starting with 534b5631 (\"SKV1\").")
                }
            }
            .navigationTitle("Paste Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        onSave()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    NavigationStack { KeyView() }.environment(BeeStore(preview: true))
}
