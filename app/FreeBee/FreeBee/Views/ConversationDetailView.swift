import BeePipeline
import SwiftData
import SwiftUI

struct ConversationDetailView: View {
    @Environment(BeeStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var playback = Playback()
    @State private var naming: SpeakerInfo?
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var bookmarks: [Date] = []
    var conversation: Conversation

    var body: some View {
        List {
            header
            if let summary = conversation.summary {
                Section("Summary") {
                    Text(summary)
                        .font(.system(.body, design: .serif))
                    if !conversation.topics.isEmpty {
                        Text(conversation.topics.joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let reason = conversation.notesError ?? conversation.failure {
                Section {
                    Label(reason, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if !conversation.todos.isEmpty {
                Section("To-dos") {
                    ForEach(conversation.todos.sorted { $0.created < $1.created }) { todo in
                        TodoRow(todo: todo)
                            .contentShape(Rectangle())
                            .onTapGesture { if let time = todo.quoteTime { playback.play(from: time, context: context) } }
                    }
                }
            }
            if !conversation.speakers.isEmpty {
                Section {
                    speakerChips
                } header: {
                    Text("Speakers")
                } footer: {
                    if conversation.speakers.contains(where: \.guessedMe) {
                        Text("\u{201C}Me\u{201D} is a guess: the loudest voice is usually the one wearing the Bee. Tap a speaker to correct it; FreeBee remembers voices you name.")
                    }
                }
            }
            transcript
        }
        // The title is the first thing in the content, so the bar stays empty.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { menu }
        .safeAreaInset(edge: .bottom) { player }
        .onDisappear { playback.stop() }
        .task { bookmarks = Processor.bookmarks(for: conversation, context: context) }
        .alert("Who is this?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                if let speaker = naming, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.processor.identify(speaker.label, in: conversation, asMe: false, name: name.trimmingCharacters(in: .whitespaces))
                }
                naming = nil
            }
            Button("Cancel", role: .cancel) { naming = nil }
        } message: {
            Text("FreeBee will recognize this voice in future conversations.")
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Conversation and Audio", role: .destructive) {
                store.processor.delete(conversation, withAudio: true)
                dismiss()
            }
            Button("Delete Notes Only", role: .destructive) {
                store.processor.delete(conversation, withAudio: false)
                dismiss()
            }
        }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(conversation.displayTitle)
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(conversation.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute())), \(Format.duration(conversation.speechSeconds)) of speech")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if conversation.soundsLikeMedia {
                    Label("Sounds like a show or video, so no to-dos were taken from it.", systemImage: "tv")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if conversation.stage == .pending {
                    Label("Waiting to be transcribed.", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(conversation.speakers.sorted { $0.seconds > $1.seconds }) { speaker in
                    Menu {
                        if !speaker.isMe || speaker.guessedMe {
                            Button("This Is Me", systemImage: "person.crop.circle.badge.checkmark") {
                                store.processor.identify(speaker.label, in: conversation, asMe: true)
                            }
                        }
                        if speaker.isMe {
                            Button("This Isn't Me", systemImage: "person.crop.circle.badge.xmark") {
                                store.processor.notMe(speaker.label, in: conversation)
                            }
                        }
                        Button("Name This Speaker…", systemImage: "pencil") {
                            name = speaker.name ?? ""
                            naming = speaker
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color(for: speaker.label)).frame(width: 8, height: 8)
                            Text(speaker.displayName + (speaker.guessedMe ? "?" : ""))
                            Text("\(Int(speaker.seconds / 60)):\(String(format: "%02d", Int(speaker.seconds) % 60))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                    }
                }
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
    }

    @ViewBuilder private var transcript: some View {
        let names = conversation.speakerNames
        let lines = conversation.sortedLines
        if !lines.isEmpty {
            Section {
                ForEach(lines) { line in
                    Button {
                        if playback.playing == line.start {
                            playback.stop()
                        } else {
                            playback.play(from: line.start, to: line.end, context: context)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(names[line.speaker] ?? line.speaker)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: line.speaker))
                                if bookmarks.contains(where: { Processor.line(line, covers: $0) }) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.honey)
                                        .accessibilityLabel("Bookmarked")
                                }
                                Spacer()
                                if playback.playing == line.start {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.honey)
                                        .symbolEffect(.variableColor.iterative)
                                }
                                Text(line.start, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(line.text)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Transcript")
            } footer: {
                Text(bookmarks.isEmpty ? "Tap a line to hear it." : "Tap a line to hear it. \(Image(systemName: "bookmark.fill")) marks where you double-pressed the Bee.")
            }
        }
    }

    @ViewBuilder private var player: some View {
        if playback.playing != nil || playback.error != nil {
            HStack {
                if let error = playback.error {
                    Label(error, systemImage: "speaker.slash").font(.footnote)
                } else {
                    Label("Playing", systemImage: "speaker.wave.2.fill").font(.subheadline.weight(.medium))
                }
                Spacer()
                Button("Stop", systemImage: "stop.fill") { playback.stop() }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal)
        }
    }

    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ShareLink(item: transcriptText, subject: Text(conversation.displayTitle)) {
                    Label("Share Transcript", systemImage: "square.and.arrow.up")
                }
                if conversation.stage == .summarized && !conversation.lines.isEmpty && NoteTaker.availability == .available {
                    Button("Summarize Again", systemImage: "sparkles") { Task { await store.processor.resummarize(conversation) } }
                }
                Button("Transcribe Again", systemImage: "text.word.spacing") { Task { await store.processor.retranscribe(conversation) } }
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .disabled(store.processor.isRunning)
        }
    }

    private var transcriptText: String {
        let names = conversation.speakerNames
        var text = "\(conversation.displayTitle)\n\(conversation.start.formatted(date: .abbreviated, time: .shortened))\n\n"
        if let summary = conversation.summary { text += summary + "\n\n" }
        for line in conversation.sortedLines {
            text += "[\(line.start.formatted(date: .omitted, time: .standard))] \(names[line.speaker] ?? line.speaker): \(line.text)\n"
        }
        return text
    }

    private func color(for label: String) -> Color {
        if conversation.speakers.first(where: { $0.label == label })?.isMe == true { return .honey }
        let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .mint]
        let number = Int(label.dropFirst()) ?? 0
        return palette[number % palette.count]
    }
}
