import BeePipeline
import SwiftData
import SwiftUI

/// How recordings become conversations, and what's kept.
struct ProcessingSettingsView: View {
    @Environment(BeeStore.self) private var store
    @Environment(\.modelContext) private var context
    @Query(sort: \SpeakerProfile.name) private var voices: [SpeakerProfile]
    @State private var bytes: Int64 = 0
    @State private var confirmDeleteAll = false

    var body: some View {
        @Bindable var processor = store.processor
        Form {
            Section {
                Picker("Engine", selection: $processor.engine) {
                    ForEach(EngineChoice.allCases) { Text($0.title).tag($0) }
                }
                if processor.engine == .parakeet {
                    if processor.parakeetReady {
                        LabeledContent("Model", value: "Downloaded")
                    } else if let progress = processor.downloading {
                        ProgressView("Downloading", value: progress)
                    } else {
                        Button("Download Parakeet (about 480 MB)", systemImage: "arrow.down.circle") {
                            Task { await processor.downloadParakeet() }
                        }
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text(processor.engine == .parakeet
                    ? "NVIDIA Parakeet v3 is the most accurate free on-device model (25 European languages). It's downloaded once from Hugging Face; after that nothing leaves this iPhone. Weights CC-BY-4.0, NVIDIA."
                    : "Apple Speech is built into iOS: no download of FreeBee's own, a little less accurate.")
            }

            Section {
                Stepper("Ends after \(processor.gapMinutes) min of silence", value: $processor.gapMinutes, in: 1...15)
                Toggle("Delete recordings with no speech", isOn: $processor.deleteSilence)
            } header: {
                Text("Conversations")
            } footer: {
                Text("Recordings with no speech in them are deleted once checked. Audio with speech is kept so you can listen back.")
            }

            Section {
                if voices.isEmpty {
                    Text("None yet. In a conversation, tap a speaker and choose \u{201C}This Is Me\u{201D} or give them a name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(voices) { voice in
                    LabeledContent(voice.isMe ? "Me" : voice.name, value: "\(voice.samples) conversation\(voice.samples == 1 ? "" : "s")")
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(voices[index]) }
                    try? context.save()
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("Voiceprints are speaker embeddings, kept on this iPhone. Knowing your voice keeps your own to-dos apart from everyone else's.")
            }

            Section {
                LabeledContent("Status", value: NoteTaker.availability == .available ? "Available" : "Unavailable")
                if NoteTaker.availability == .available {
                    LabeledContent("Model", value: NoteTaker.modelDescription)
                } else if let reason = NoteTaker.availability.explanation {
                    Text(reason).foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("Summaries and to-dos come from Apple's on-device model. FreeBee never uses Private Cloud Compute.")
            }

            Section {
                LabeledContent("Recordings", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                Button("Delete All Recordings and Notes", role: .destructive) { confirmDeleteAll = true }
            } header: {
                Text("Storage")
            } footer: {
                Text("About 14 MB per hour of audio. Recordings stay on this iPhone and aren't in iCloud backups.")
            }
        }
        .navigationTitle("Conversations")
        .task { bytes = Library.bytesOnDisk() }
        .confirmationDialog("Delete everything?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                store.processor.deleteEverything()
                bytes = Library.bytesOnDisk()
            }
        } message: {
            Text("All recordings, transcripts, notes and to-dos on this iPhone. Voices are kept.")
        }
    }
}
